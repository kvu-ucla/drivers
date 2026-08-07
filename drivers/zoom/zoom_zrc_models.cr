module Zoom::ZRC
  struct JoinMeetingRequest
    include JSON::Serializable

    getter meeting_number : String
    getter password : String?
    getter bring_share : Bool

    def initialize(@meeting_number, @password = nil, @bring_share = false)
    end
  end

  struct PairRoomRequest
    include JSON::Serializable

    getter activation_code : String

    def initialize(@activation_code)
    end
  end

  # Doubles as the request body and the parsed response for start_meeting.
  # Only meeting_number is required; the rest are nilable so that unset fields
  # are omitted from the request body (JSON::Serializable skips nil by default).
  struct StartMeetingRequest
    include JSON::Serializable

    getter meeting_number : String
    getter meeting_name : String?
    getter host_name : String?
    getter start_time : String?
    getter end_time : String?
    getter bring_share : Bool?

    def initialize(
      @meeting_number,
      @meeting_name = nil,
      @host_name = nil,
      @start_time = nil,
      @end_time = nil,
      @bring_share = nil,
    )
    end
  end
end
