# UCLA-maintained copy of drivers/zoom/booking_converter.cr (vendored 2026-09-04 from ucla-dev @ b479ebe0a5)
# Version 1.0.0 — documentation: booking_converter_readme.md
require "placeos-driver"
require "place_calendar"

class Zoom::BookingConverter < PlaceOS::Driver
  descriptive_name "Convert Zoom Bookings to PlaceOS Calendar Events (UCLA)"
  generic_name :Bookings
  description %(Subscribes to the Zoom ZRC module's meetings list and exposes it as PlaceOS Calendar events)

  default_settings({
    booking_source: {
      module: "ZoomZRC_1",
      status: "meetings",
    },
  })

  struct BookingSource
    include JSON::Serializable

    @[JSON::Field(key: "module")]
    getter module_name : String = "ZoomZRC_1"
    getter status : String = "meetings"

    def initialize(@module_name = "ZoomZRC_1", @status = "meetings")
    end
  end

  # A meetings-list entry as published by the ZRC wrapper. The same status is
  # written from two wrapper paths with different key casing:
  # - GET /meetings/list responses use snake_case (meeting_item_to_dict in
  #   service/controllers/meeting_list.py)
  # - OnUpdateMeetingList push events use the raw pybind camelCase attribute
  #   names (_pybind_to_jsonable in service/room_manager.py)
  # Keys are underscore-normalized before parsing (see #normalize_entry), so
  # each field is declared once in its snake_case form.
  struct ZRCMeeting
    include JSON::Serializable

    getter meeting_number : String?
    getter meeting_name : String?
    getter start_time : String?
    getter end_time : String?
    getter is_private : Bool?
    getter is_all_day_event : Bool?

    def number : String?
      meeting_number.try &.presence
    end

    def name : String
      meeting_name || ""
    end

    def starts_at : Time?
      parse_time(start_time)
    end

    def ends_at : Time?
      parse_time(end_time)
    end

    def private? : Bool
      is_private || false
    end

    def all_day? : Bool
      is_all_day_event || false
    end

    private def parse_time(value : String?) : Time?
      value = value.try &.presence
      return nil unless value
      Time.parse_rfc3339(value)
    rescue Time::Format::Error
      nil
    end
  end

  # bumped on every (re)subscribe; a callback holding a stale generation is
  # from a previous subscription and must not touch state
  @source_generation : UInt64 = 0_u64

  def on_load
    on_update
  end

  def on_update
    source = setting?(BookingSource, :booking_source) || BookingSource.new
    generation = @source_generation += 1

    subscriptions.clear
    system.subscribe(source.module_name, source.status) do |_subscription, new_data|
      # a callback fiber dispatched just before re-subscribe can land an
      # in-flight payload from the OLD source after the new source is active —
      # drop it rather than overwrite the new source's bookings
      next unless generation == @source_generation
      logger.debug { "detected change in #{source.module_name}/#{source.status}: #{new_data}" }
      if new_data.strip == "null"
        # the source status was deleted or explicitly cleared upstream
        expose_bookings([] of JSON::Any, generation)
      else
        begin
          expose_bookings(Array(JSON::Any).from_json(new_data), generation)
        rescue error : JSON::ParseException
          # never conflate "source glitched" with "no meetings" — keep the
          # last-known-good bookings when the payload is unparseable
          logger.warn { "ignoring unparsable #{source.module_name}/#{source.status} payload, keeping existing bookings (#{error.message})" }
        end
      end
    end

    # ensure current booking is updated at the start of every minute
    # rand spreads the load placed on redis
    schedule.clear
    schedule.cron("* * * * *") do
      schedule.in(rand(1000).milliseconds) do
        if list = self[:bookings]?
          determine_current_booking(list.as_a)
          determine_next_booking(list.as_a)
        end
      end
    end
  end

  private def expose_bookings(zrc_meetings : Array(JSON::Any), generation : UInt64)
    placeos_bookings = [] of Hash(String, Array(Bool) | Bool | Int64 | String | Nil)
    zrc_meetings.each do |entry|
      meeting = begin
        ZRCMeeting.from_json(normalize_entry(entry))
      rescue error : JSON::SerializableError
        logger.warn { "skipping unparsable meetings entry: #{entry.inspect} (#{error.message})" }
        next
      end

      number = meeting.number
      starts_at = meeting.starts_at
      ends_at = meeting.ends_at
      # UCLA ZRC room calendars contain only Zoom meetings, so an entry without
      # a meeting number is skipped by design (see booking_converter_readme.md);
      # blank times cover instant meetings, which are not calendar bookings
      unless number && starts_at && ends_at
        logger.warn { "skipping meetings entry missing meeting number or times: #{entry.inspect}" }
        next
      end

      placeos_bookings << convert_booking(meeting, number, starts_at, ends_at)
    end
    placeos_bookings.sort_by! { |booking| booking["event_start"].as(Int64) }
    guarded_write(generation, :bookings, placeos_bookings)

    list = JSON.parse(placeos_bookings.to_json).as_a
    determine_current_booking(list, generation)
    determine_next_booking(list, generation)
  end

  # Crystal fibers are cooperative and every status write is redis IO — a
  # yield point — so a callback fiber that passed the generation check on
  # entry can be suspended mid-way through its writes while a newer on_update
  # bumps the generation. Re-verify immediately before EACH write so a stale
  # fiber stops writing the moment it resumes. Cron-driven recomputes pass
  # nil: they read current state, so there is no stale source to guard.
  private def guarded_write(generation : UInt64?, key, value)
    return if generation && generation != @source_generation
    self[key] = value
  end

  # camelCase event-push keys → snake_case, so ZRCMeeting needs one spelling
  private def normalize_entry(entry : JSON::Any) : String
    if hash = entry.as_h?
      hash.transform_keys(&.underscore).to_json
    else
      entry.to_json
    end
  end

  private def convert_booking(meeting : ZRCMeeting, number : String, starts_at : Time, ends_at : Time)
    {
      "title"       => meeting.name,
      "body"        => "",
      "location"    => "",
      "event_start" => starts_at.to_unix,
      "event_end"   => ends_at.to_unix,
      "id"          => number,

      "recurring_event_id" => nil,
      "attendees"          => [] of Bool,
      "attachments"        => [] of Bool,
      "timezone"           => nil,
      "recurring"          => false,
      "created"            => nil,
      "updated"            => nil,
      "recurrence"         => nil,
      "status"             => nil,
      "creator"            => nil,
      "ical_uid"           => nil,
      "private"            => meeting.private?,
      "all_day"            => meeting.all_day?,
    }
  end

  private def determine_current_booking(bookings : Array(JSON::Any), generation : UInt64? = nil)
    if bookings.empty?
      guarded_write(generation, :current_booking, nil)
      guarded_write(generation, :booking_in_progress, false)
      return
    end
    current_time = Time.utc.to_unix
    current_booking = bookings.find do |booking|
      booking["event_start"].as_i64 <= current_time && booking["event_end"].as_i64 > current_time
    end
    guarded_write(generation, :current_booking, current_booking || nil)
    guarded_write(generation, :booking_in_progress, !current_booking.nil?)
  end

  private def determine_next_booking(bookings : Array(JSON::Any), generation : UInt64? = nil)
    if bookings.empty?
      guarded_write(generation, :next_booking, nil)
      return
    end
    current_time = Time.utc.to_unix
    next_booking = bookings.find do |booking|
      booking["event_start"].as_i64 > current_time
    end
    guarded_write(generation, :next_booking, next_booking || nil)
  end
end
