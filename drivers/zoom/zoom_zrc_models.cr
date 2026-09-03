module Zoom::ZRC
  # Pure helpers for normalising SDK wrapper responses and deciding whether a
  # notification represents a prompt a room UI can actually answer.
  module EventState
    extend self

    def meeting_status(payload : JSON::Any) : String?
      raw_status = payload.as_h?.try(&.["status"]?).try(&.as_s?) || payload.as_s?
      raw_status.try(&.split('.').last)
    end

    def meeting_active?(payload : JSON::Any) : Bool
      meeting_status(payload) == "MeetingStatusInMeeting"
    end

    # Only terminal states are safe evidence that meeting-scoped prompts and
    # informational notifications are stale. Transient statuses (for example,
    # connecting or waiting for host) still belong to the pending session.
    def meeting_session_ended?(status : String?) : Bool
      status.nil? || status == "MeetingStatusNotInMeeting" || status == "MeetingStatusLoggedOut"
    end

    # REST controllers expose connection states in a few equivalent forms
    # ("Connected", "ConnectionStateConnected", or
    # "ConnectionState.ConnectionStateConnected"). WebSocket callbacks use the
    # enum member name. Keep the public status stable regardless of the source.
    def connection_state(payload : JSON::Any) : String?
      raw_state = payload.as_h?.try(&.["connection_state"]?).try(&.as_s?) || payload.as_s?
      state = raw_state.try(&.split('.').last)
      case state
      when "None", "Established", "Connected", "Disconnected"
        "ConnectionState#{state}"
      else
        state
      end
    end

    def connection_online?(payload : JSON::Any) : Bool
      connection_state(payload) == "ConnectionStateConnected"
    end

    def actionable_prompt?(event_name : String, event : JSON::Any) : Bool
      case event_name
      when "OnConsentNotification"
        visible = event.dig?("info", "is_showing") || event.dig?("info", "isShowing")
        visible.try(&.as_bool?) != false
      when "OnCombinedConsentNotification"
        visible = event.dig?("combinedConsent", "is_showing") || event.dig?("combinedConsent", "isShowing")
        visible.try(&.as_bool?) != false
      when "OnConsolidatedCustomizedConsentNotification"
        # Unlike legacy reminder callbacks, SDK 7.1 exposes no show/hide flag.
        # Receipt means the consolidated consent is blocking and actionable.
        true
      when "OnMeetingReminderNotification"
        visible = event.dig?("reminderContent", "is_showing") || event.dig?("reminderContent", "isShowing")
        visible.try(&.as_bool?) != false
      when "OnCustomizedReminderNotification"
        visible = event.dig?("customizedContent", "is_showing") || event.dig?("customizedContent", "isShowing")
        visible.try(&.as_bool?) != false
      when "OnPrivacyAlertNotification"
        action = event["action"]? || event["privacyAlertAction"]? || event.dig?("info", "action") || event.dig?("info", "privacyAlertAction")
        action_name = action.try(&.as_s?)
        action_value = action.try(&.as_i?)
        case action_name
        when "PRIVACY_ALERT_ACTION_NONE", "PRIVACY_ALERT_ACTION_CLOSE", "PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER"
          false
        when "PRIVACY_ALERT_ACTION_SHOW", "PRIVACY_ALERT_ACTION_SHOW_DISCLAIMER"
          true
        else
          if action_name
            # Preserve a future named SHOW-style action rather than silently
            # discarding a real prompt added by a newer SDK.
            true
          else
            case action_value
            when 0, 2, 4, nil
              false
            when 1, 3
              true
            else
              # The wrapper currently emits enum names. Preserve unknown future
              # nonzero integer actions as visible rather than dropping a prompt.
              action_value != 0
            end
          end
        end
      when "OnInactiveDetectionNotification"
        event["isShowPrompt"]?.try(&.as_bool?) != false
      when "OnJBHWaitingHostNotification"
        event["showWaitForHostDialog"]?.try(&.as_bool?) != false
      when "OnAskUnmuteAudioByHostNotification"
        event["show"]?.try(&.as_bool?) != false
      when "OnReceiveAICompanionRequest"
        request_type = event.dig?("info", "type")
        switch_action = event.dig?("info", "switchAction")
        is_switch = request_type.try(&.as_s?) == "AICompanionRequestSwitch"
        action_name = switch_action.try(&.as_s?)
        action_value = switch_action.try(&.as_i?)
        is_switch && (action_name.in?(
          "AICompanionSwitchActionTurnOn",
          "AICompanionSwitchActionTurnOff"
        ) || action_value.in?(1, 2))
      else
        true
      end
    end

    # OnUpdateAirPlayBlackMagicStatus extraction lives here (below the event
    # dispatcher's rescue) so specs can prove it never raises on missing, null
    # or wrong-type input rather than the raise being swallowed into a
    # "bad event payload" log line.
    def sharing_payload(event : JSON::Any) : Hash(String, JSON::Any)?
      event.as_h?.try(&.["status"]?).try(&.as_h?)
    end

    # Derived sharing signals: {hdmi_sharing, sharing_key, airplay_client_connected}.
    # Nil means "absent or wrong type" so the caller preserves prior state.
    def sharing_signals(sharing : Hash(String, JSON::Any)) : {Bool?, String?, Bool?}
      {
        sharing["isSharingBlackMagic"]?.try(&.as_bool?),
        sharing["directPresentationSharingKey"]?.try(&.as_s?),
        sharing["isAirHostClientConnected"]?.try(&.as_bool?),
      }
    end
  end

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
