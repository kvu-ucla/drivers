require "placeos-driver/spec"

# :nodoc:
class ZoomZRC < DriverSpecs::MockDriver
  def on_load
  end
end

DriverSpecs.mock_driver "Zoom::BookingConverter" do
  system({ZoomZRC: {ZoomZRC, ZoomZRC}})
  sleep 500.milliseconds # allow the driver to subscribe after the system is defined

  now = Time.utc
  current_start = now - 10.minutes
  current_end = now + 20.minutes
  next_start = now + 30.minutes
  next_end = now + 60.minutes

  # REST /meetings/list shape: snake_case keys as serialized by the wrapper's
  # meeting_item_to_dict (service/controllers/meeting_list.py). Listed with the
  # future meeting first to prove bookings are sorted by start time. The last
  # two entries are malformed (missing meeting_number / blank instant-meeting
  # times) and must be skipped without dropping the valid ones.
  rest_meetings = %([
    {
      "zoom_meeting_item_type": 1,
      "meeting_number": "111222333",
      "meeting_name": "Future Planning",
      "host_name": "Bruin Host",
      "start_time": "#{next_start.to_rfc3339}",
      "end_time": "#{next_end.to_rfc3339}",
      "scheduled_from": "Google Calendar",
      "is_private": true,
      "is_all_day_event": false,
      "is_checked_in": false,
      "meeting_domain": "https://ucla.zoom.us",
      "is_instant_meeting": false,
      "third_party_meeting_info": {"service_provider": 0, "meeting_number": "", "sip_address": "", "h323_address": "", "join_meeting_url": "", "dial_numbers": []},
      "scheduled_by_info": {"user_id": "u-100", "user_name": "Bruin Host", "user_avatar_url": ""}
    },
    {
      "zoom_meeting_item_type": 1,
      "meeting_number": "987654321",
      "meeting_name": "AVITS Weekly Sync",
      "host_name": "Kenneth Vu",
      "start_time": "#{current_start.to_rfc3339}",
      "end_time": "#{current_end.to_rfc3339}",
      "scheduled_from": "Google Calendar",
      "is_private": false,
      "is_all_day_event": false,
      "is_checked_in": true,
      "meeting_domain": "https://ucla.zoom.us",
      "is_instant_meeting": false,
      "third_party_meeting_info": {"service_provider": 0, "meeting_number": "", "sip_address": "", "h323_address": "", "join_meeting_url": "", "dial_numbers": []},
      "scheduled_by_info": {"user_id": "u-200", "user_name": "Kenneth Vu", "user_avatar_url": ""}
    },
    {
      "meeting_name": "No Number",
      "start_time": "#{next_start.to_rfc3339}",
      "end_time": "#{next_end.to_rfc3339}"
    },
    {
      "meeting_number": "555000111",
      "meeting_name": "Instant Meeting",
      "start_time": "",
      "end_time": "",
      "is_instant_meeting": true
    }
  ])
  system(:ZoomZRC_1)[:meetings] = JSON.parse(rest_meetings)

  50.times do
    break if status[:bookings]?.try(&.as_a?.try(&.size.== 2))
    sleep 100.milliseconds
  end

  bookings = status[:bookings].as_a
  bookings.size.should eq 2

  # sorted by start time, so the in-progress meeting comes first
  current = bookings[0]
  current["title"].should eq "AVITS Weekly Sync"
  current["id"].should eq "987654321"
  current["event_start"].should eq current_start.to_unix
  current["event_end"].should eq current_end.to_unix
  current["body"].should eq ""
  current["location"].should eq ""
  current["private"].should eq false
  current["all_day"].should eq false
  current["recurring"].should eq false
  current["attendees"].as_a.should be_empty
  current["attachments"].as_a.should be_empty
  current["recurring_event_id"].raw.should be_nil
  current["timezone"].raw.should be_nil

  upcoming = bookings[1]
  upcoming["title"].should eq "Future Planning"
  upcoming["id"].should eq "111222333"
  upcoming["event_start"].should eq next_start.to_unix
  upcoming["event_end"].should eq next_end.to_unix
  upcoming["private"].should eq true

  # current/next determination should not wait for the next cron tick.
  # next_booking is the last status written per update, so polling it means
  # bookings/current_booking/booking_in_progress have already landed.
  50.times do
    break if status[:next_booking]?.try(&.["id"]?.try(&.==("111222333")))
    sleep 100.milliseconds
  end
  status[:booking_in_progress].should eq true
  status[:current_booking]["id"].should eq "987654321"
  status[:next_booking]["id"].should eq "111222333"

  # OnMeetingListUpdate event shape: camelCase pybind attribute names as
  # serialized by the wrapper's _pybind_to_jsonable (service/room_manager.py)
  event_meetings = %([
    {
      "zoomMeetingItemType": "ZoomMeetingItemTypeScheduled",
      "meetingNumber": "444555666",
      "meetingName": "Event Push Meeting",
      "hostName": "Bruin Host",
      "startTime": "#{next_start.to_rfc3339}",
      "endTime": "#{next_end.to_rfc3339}",
      "scheduledFrom": "Google Calendar",
      "isPrivate": false,
      "isAllDayEvent": true,
      "isCheckedIn": false,
      "meetingDomain": "https://ucla.zoom.us",
      "isInstantMeeting": false,
      "thirdPartyMeetingInfo": {"serviceProvider": "ServiceProviderUnknown", "meetingNumber": "", "sipAddress": "", "h323Address": "", "joinMeetingURL": "", "dialNumbers": []},
      "scheduledByInfo": {"userID": "u-300", "userName": "Bruin Host", "userAvatarURL": ""}
    }
  ])
  system(:ZoomZRC_1)[:meetings] = JSON.parse(event_meetings)

  50.times do
    break if status[:next_booking]?.try(&.["id"]?.try(&.==("444555666")))
    sleep 100.milliseconds
  end

  pushed = status[:bookings].as_a[0]
  pushed["id"].should eq "444555666"
  pushed["title"].should eq "Event Push Meeting"
  pushed["event_start"].should eq next_start.to_unix
  pushed["event_end"].should eq next_end.to_unix
  pushed["all_day"].should eq true
  status[:booking_in_progress].should eq false
  status[:current_booking]?.try(&.raw).should be_nil
  status[:next_booking]["id"].should eq "444555666"

  # changing booking_source re-subscribes to the new module/status
  settings({booking_source: {module: "ZoomZRC_2", status: "meetings"}})
  sleep 500.milliseconds

  second_source = %([
    {
      "meeting_number": "777888999",
      "meeting_name": "From Second Module",
      "start_time": "#{next_start.to_rfc3339}",
      "end_time": "#{next_end.to_rfc3339}"
    }
  ])
  system(:ZoomZRC_2)[:meetings] = JSON.parse(second_source)

  50.times do
    break if status[:next_booking]?.try(&.["id"]?.try(&.==("777888999")))
    sleep 100.milliseconds
  end
  status[:bookings].as_a[0]["id"].should eq "777888999"

  # the old source must not clobber bookings after a source change. Two driver
  # mechanisms enforce this: the old subscription is unsubscribed, and a
  # generation guard drops callbacks captured by a previous subscription — both
  # at callback entry and re-checked before each individual status write (every
  # write is redis IO, a fiber yield point, so a stale fiber could otherwise
  # resume mid-sequence after a newer on_update). Only the unsubscribe path is
  # deterministically reproducible here — the harness cannot control callback
  # delivery ordering or suspend a driver fiber between writes to stage either
  # race — so this exercises the observable no-clobber behaviour and the
  # generation guards are covered by code inspection (on_update/guarded_write).
  system(:ZoomZRC_1)[:meetings] = JSON.parse(event_meetings)
  sleep 500.milliseconds
  status[:bookings].as_a[0]["id"].should eq "777888999"

  # an unparseable (non-null, non-array) payload must keep existing state,
  # never conflating "source glitched" with "no meetings"
  system(:ZoomZRC_2)[:meetings] = "not an array"
  sleep 500.milliseconds
  status[:bookings].as_a[0]["id"].should eq "777888999"
  status[:next_booking]["id"].should eq "777888999"

  # an explicit null meetings payload clears the list and booking state
  system(:ZoomZRC_2)[:meetings] = JSON.parse("null")
  50.times do
    break if status[:bookings]?.try(&.as_a?.try(&.empty?)) && status[:next_booking]?.nil?
    sleep 100.milliseconds
  end
  status[:bookings].as_a.should be_empty
  status[:booking_in_progress].should eq false
  status[:current_booking]?.try(&.raw).should be_nil
  status[:next_booking]?.try(&.raw).should be_nil
end
