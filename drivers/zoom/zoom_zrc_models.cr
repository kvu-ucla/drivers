module Zoom::ZRC
  struct JoinMeetingRequest
    include JSON::Serializable

    getter meeting_number : String
    getter password : String?
    getter bring_share : Bool

    def initialize(@meeting_number, @password = nil, @bring_share = false)
    end
  end

  struct StartMeetingRequest
    include JSON::Serializable

    getter meeting_number : String
    getter meeting_name : String
    getter host_name : String
    getter start_time : String
    getter end_time : String
    getter bring_share : Bool

    def initialize(
      @meeting_number,
      @meeting_name = "",
      @host_name = "",
      @start_time = "",
      @end_time = "",
      @bring_share = false,
    )
    end
  end
end
