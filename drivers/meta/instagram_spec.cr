require "placeos-driver/spec"

DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_long_lived_token_abc123",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle the initial feed fetch that happens in on_update
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  sleep 100.milliseconds

  # ==========================================================================
  # Test: Feed fetch with IMAGE, VIDEO, and CAROUSEL posts
  # ==========================================================================
  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    # Verify the request is correct and includes all required parameters
    if request.path.includes?("/v25.0/me/media") &&
       request.query_params["access_token"]? == "test_long_lived_token_abc123" &&
       request.query_params["limit"]? == "25"

      # Verify all required fields are requested
      fields = request.query_params["fields"]?
      fields.should_not be_nil
      fields.not_nil!.should contain("id")
      fields.not_nil!.should contain("media_type")
      fields.not_nil!.should contain("media_url")
      fields.not_nil!.should contain("children{media_type,media_url,thumbnail_url,id}")

      response.status_code = 200
      response << <<-JSON
      {
        "data": [
          {
            "id": "img_001",
            "media_type": "IMAGE",
            "media_url": "https://scontent.cdninstagram.com/v/image1.jpg?oe=1234",
            "permalink": "https://instagram.com/p/img001",
            "caption": "Beautiful sunset at the beach",
            "timestamp": "2024-01-15T10:30:00+0000",
            "username": "testuser"
          },
          {
            "id": "vid_001",
            "media_type": "VIDEO",
            "media_url": "https://scontent.cdninstagram.com/v/video1.mp4?oe=5678",
            "thumbnail_url": "https://scontent.cdninstagram.com/v/thumb1.jpg?oe=5678",
            "permalink": "https://instagram.com/p/vid001",
            "caption": "Amazing Reel!",
            "timestamp": "2024-01-14T15:45:00+0000",
            "username": "testuser"
          },
          {
            "id": "car_001",
            "media_type": "CAROUSEL_ALBUM",
            "media_url": "https://scontent.cdninstagram.com/v/carousel_parent.jpg",
            "permalink": "https://instagram.com/p/car001",
            "caption": "Carousel post with multiple images",
            "timestamp": "2024-01-13T08:00:00+0000",
            "username": "testuser",
            "children": {
              "data": [
                {
                  "id": "car_001_child_1",
                  "media_type": "IMAGE",
                  "media_url": "https://scontent.cdninstagram.com/v/carousel1.jpg?oe=1111"
                },
                {
                  "id": "car_001_child_2",
                  "media_type": "IMAGE",
                  "media_url": "https://scontent.cdninstagram.com/v/carousel2.jpg?oe=2222"
                },
                {
                  "id": "car_001_child_3",
                  "media_type": "VIDEO",
                  "media_url": "https://scontent.cdninstagram.com/v/carousel3.mp4?oe=3333",
                  "thumbnail_url": "https://scontent.cdninstagram.com/v/carousel3_thumb.jpg?oe=3333"
                }
              ]
            }
          },
          {
            "id": "img_002",
            "media_type": "IMAGE",
            "caption": null,
            "permalink": "https://instagram.com/p/img002",
            "timestamp": "2024-01-12T12:00:00+0000",
            "username": "testuser"
          }
        ],
        "paging": {
          "cursors": {
            "before": "before_cursor",
            "after": "after_cursor"
          },
          "next": "https://graph.instagram.com/v25.0/me/media?after=after_cursor&access_token=test_long_lived_token_abc123"
        }
      }
      JSON
    else
      response.status_code = 400
      response << %({
        "error": {
          "message": "Invalid request",
          "type": "OAuthException",
          "code": 400
        }
      })
    end
  end

  # Verify the slides were mapped correctly
  sleep 100.milliseconds # Give the async fetch time to complete
  slides = status[:slides].as_a

  # Should have 4 slides (3 complete posts + 1 without media_url that should be dropped)
  slides.size.should eq 3

  # Check IMAGE mapping
  image_slide = slides[0].as_h
  image_slide["id"].should eq "img_001"
  image_slide["type"].should eq "image"
  image_slide["url"].should eq "https://scontent.cdninstagram.com/v/image1.jpg?oe=1234"
  image_slide["caption"].should eq "Beautiful sunset at the beach"
  image_slide["permalink"].should eq "https://instagram.com/p/img001"
  image_slide["username"].should eq "testuser"
  image_slide["timestamp"].should eq "2024-01-15T10:30:00+0000"

  # Check VIDEO mapping
  video_slide = slides[1].as_h
  video_slide["id"].should eq "vid_001"
  video_slide["type"].should eq "video"
  video_slide["url"].should eq "https://scontent.cdninstagram.com/v/video1.mp4?oe=5678"
  video_slide["thumbnail"].should eq "https://scontent.cdninstagram.com/v/thumb1.jpg?oe=5678"
  video_slide["caption"].should eq "Amazing Reel!"

  # Check CAROUSEL mapping
  carousel_slide = slides[2].as_h
  carousel_slide["id"].should eq "car_001"
  carousel_slide["type"].should eq "carousel"
  carousel_slide["caption"].should eq "Carousel post with multiple images"
  carousel_slide["permalink"].should eq "https://instagram.com/p/car001"

  children = carousel_slide["children"].as_a
  children.size.should eq 3
  children[0].as_h["type"].should eq "image"
  children[0].as_h["url"].should eq "https://scontent.cdninstagram.com/v/carousel1.jpg?oe=1111"
  children[2].as_h["type"].should eq "video"
  children[2].as_h["thumbnail"].should eq "https://scontent.cdninstagram.com/v/carousel3_thumb.jpg?oe=3333"

  # Check poll state
  status[:poll_state].should eq "success"
  status[:last_poll_at].as_i64.should be > 0

  # ==========================================================================
  # Test: Token refresh
  # ==========================================================================
  retval = exec(:refresh_token)

  expect_http_request do |request, response|
    if request.path.includes?("/refresh_access_token") &&
       request.query_params["grant_type"]? == "ig_refresh_token" &&
       request.query_params["access_token"]? == "test_long_lived_token_abc123"
      response.status_code = 200
      response << <<-JSON
      {
        "access_token": "refreshed_token_xyz789",
        "token_type": "bearer",
        "expires_in": 5184000
      }
      JSON
    else
      response.status_code = 400
      response << %({
        "error": {
          "message": "Invalid token refresh request",
          "type": "OAuthException",
          "code": 400
        }
      })
    end
  end

  # Give time for async operation
  sleep 100.milliseconds

  # Verify token was refreshed
  status[:token_state].should eq "valid"
  status[:token_expires_at].as_i64.should be > Time.utc.to_unix
  status[:last_token_refresh].as_i64.should be > 0

  # ==========================================================================
  # Test: Feed fetch failure handling
  # ==========================================================================
  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 403
    response << %({
      "error": {
        "message": "Insufficient permissions",
        "type": "OAuthException",
        "code": 10
      }
    })
  end

  sleep 100.milliseconds

  # Should mark poll as failed
  status[:poll_state].should eq "failed"
  status[:poll_error]?.should_not be_nil

  # ==========================================================================
  # Test: Status endpoint
  # ==========================================================================
  retval = exec(:status)
  status_response = retval.get.as_h

  status_response["poll_state"]?.should_not be_nil
  status_response["token_state"]?.should_not be_nil

  token_expires = status_response["token_expires_at"]?
  token_expires.should_not be_nil
  token_expires.not_nil!.as_i64.should be > 0

  poll_interval = status_response["poll_interval_min"]?
  poll_interval.should_not be_nil
  poll_interval.not_nil!.as_i.should eq 30

  # ==========================================================================
  # Test: Manual trigger methods
  # ==========================================================================
  retval = exec(:trigger_feed_fetch)
  retval.get.should eq "Feed fetch triggered"

  # Handle the async HTTP request triggered by trigger_feed_fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  sleep 100.milliseconds

  retval = exec(:trigger_token_refresh)
  retval.get.should eq "Token refresh triggered"

  # The token is less than 24h old so refresh will be skipped - no HTTP mock needed
  sleep 100.milliseconds

  # ==========================================================================
  # Test: Empty/missing URL filtering
  # ==========================================================================
  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-JSON
    {
      "data": [
        {
          "id": "valid_001",
          "media_type": "IMAGE",
          "media_url": "https://scontent.cdninstagram.com/valid.jpg",
          "permalink": "https://instagram.com/p/valid001",
          "caption": "Valid post",
          "timestamp": "2024-01-15T10:30:00+0000",
          "username": "testuser"
        },
        {
          "id": "invalid_001",
          "media_type": "IMAGE",
          "permalink": "https://instagram.com/p/invalid001",
          "caption": "Missing media_url - should be dropped",
          "timestamp": "2024-01-14T10:30:00+0000",
          "username": "testuser"
        },
        {
          "id": "carousel_empty",
          "media_type": "CAROUSEL_ALBUM",
          "permalink": "https://instagram.com/p/carousel_empty",
          "caption": "Carousel with no children - should be dropped",
          "timestamp": "2024-01-13T10:30:00+0000",
          "username": "testuser",
          "children": {
            "data": []
          }
        }
      ]
    }
    JSON
  end

  sleep 100.milliseconds
  slides = status[:slides].as_a

  # Should only have 1 valid slide (invalid posts dropped)
  slides.size.should eq 1
  slides[0].as_h["id"].should eq "valid_001"
end

# ==========================================================================
# TOKEN MANAGEMENT EDGE CASES
# Tests for token refresh failures and expiry scenarios
# ==========================================================================

# Test: Token refresh failure with 401 error
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "old_failing_token",
    token_expires_at:      Time.utc.to_unix - 25.hours.total_seconds.to_i64 + 60.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  sleep 100.milliseconds

  # Explicitly trigger token refresh
  retval = exec(:refresh_token)

  # Handle token refresh request
  expect_http_request do |request, response|
    response.status_code = 401
    response << %({
      "error": {
        "message": "Invalid OAuth access token",
        "type": "OAuthException",
        "code": 190
      }
    })
  end

  sleep 200.milliseconds

  # Verify token refresh failed
  status[:token_state].should eq "failed"
  status[:token_error]?.should_not be_nil

  error_info = status[:token_error].as_h
  error_info["code"].as_i.should eq 401
end

# Test: Token refresh with missing access_token in response
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "token_missing_response",
    token_expires_at:      Time.utc.to_unix - 25.hours.total_seconds.to_i64 + 60.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  sleep 100.milliseconds

  # Explicitly trigger token refresh
  retval = exec(:refresh_token)

  # Handle token refresh - return success but without access_token
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "token_type": "bearer",
      "expires_in": 5184000
    })
  end

  sleep 200.milliseconds

  # Verify token state shows invalid response
  status[:token_state].should eq "invalid_response"
end

# Test: Expired token detection on startup
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "expired_token",
    token_expires_at:      Time.utc.to_unix - 1.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  sleep 100.milliseconds

  # Verify expired token is detected
  status[:token_state].should eq "expired"
end

# Test: Token with no expiry tracking gets refreshed
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "token_no_expiry",
    token_expires_at:      0_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": []
    })
  end

  # Handle token refresh attempt (should be triggered for unknown tokens)
  expect_http_request do |request, response|
    if request.path.includes?("/refresh_access_token")
      response.status_code = 200
      response << %({
        "access_token": "new_token_with_expiry",
        "token_type": "bearer",
        "expires_in": 5184000
      })
    else
      response.status_code = 200
      response << %({"data": []})
    end
  end

  sleep 200.milliseconds

  # Verify token was refreshed and now has expiry tracking
  status[:token_state].should eq "valid"
  token_expires = status[:token_expires_at]?
  token_expires.should_not be_nil
  token_expires.not_nil!.as_i64.should be > Time.utc.to_unix
end

# Test: Token refresh request includes correct parameters
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "token_param_check",
    token_expires_at:      Time.utc.to_unix - 25.hours.total_seconds.to_i64 + 60.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  # Explicitly trigger token refresh to test request parameters
  retval = exec(:refresh_token)

  # Verify token refresh request parameters
  expect_http_request do |request, response|
    # Verify required parameters
    request.query_params["grant_type"]?.should eq "ig_refresh_token"
    request.query_params["access_token"]?.should eq "token_param_check"

    response.status_code = 200
    response << %({
      "access_token": "refreshed_token",
      "token_type": "bearer",
      "expires_in": 5184000
    })
  end

  sleep 200.milliseconds

  status[:token_state].should eq "valid"
end
# Spec file for edge cases: malformed responses, network errors, and data validation
# Tests the driver's resilience to unexpected API behavior

# ==========================================================================
# Test: Malformed JSON response in feed fetch
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  # Test malformed JSON response
  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({invalid json here)
  end

  sleep 1000.milliseconds

  # Should handle error gracefully
  status[:poll_state].should eq "error"
  status[:poll_error]?.should_not be_nil
end

# ==========================================================================
# Test: Empty response body
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %()
  end

  sleep 1000.milliseconds

  # Should handle empty response
  status[:poll_state].should eq "error"
end

# ==========================================================================
# Test: Response with missing "data" field
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "paging": {
        "cursors": {
          "before": "abc",
          "after": "xyz"
        }
      }
    })
  end

  sleep 1000.milliseconds

  # Should handle missing data field
  status[:poll_state].should eq "error"
end

# ==========================================================================
# Test: Carousel with children but missing "data" array
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": [
        {
          "id": "car_001",
          "media_type": "CAROUSEL_ALBUM",
          "permalink": "https://instagram.com/p/car001",
          "caption": "Carousel with malformed children",
          "timestamp": "2024-01-13T08:00:00+0000",
          "username": "testuser",
          "children": {
            "malformed": true
          }
        }
      ]
    })
  end

  sleep 100.milliseconds

  # Carousel should be filtered out, resulting in empty slides
  slides = status[:slides]?.try(&.as_a) || [] of JSON::Any
  slides.size.should eq 0
end

# ==========================================================================
# Test: Carousel with children containing invalid media items
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": [
        {
          "id": "car_002",
          "media_type": "CAROUSEL_ALBUM",
          "permalink": "https://instagram.com/p/car002",
          "caption": "Carousel with mix of valid and invalid children",
          "timestamp": "2024-01-13T08:00:00+0000",
          "username": "testuser",
          "children": {
            "data": [
              {
                "id": "child_1",
                "media_type": "IMAGE",
                "media_url": "https://scontent.cdninstagram.com/valid.jpg"
              },
              {
                "id": "child_2",
                "media_type": "IMAGE"
              },
              {
                "id": "child_3"
              },
              {
                "id": "child_4",
                "media_type": "VIDEO",
                "media_url": "https://scontent.cdninstagram.com/valid.mp4",
                "thumbnail_url": "https://scontent.cdninstagram.com/thumb.jpg"
              }
            ]
          }
        }
      ]
    })
  end

  sleep 100.milliseconds

  # Should have 1 carousel with only 2 valid children (child_1 and child_4)
  slides = status[:slides].as_a
  slides.size.should eq 1

  carousel = slides[0].as_h
  carousel["type"].should eq "carousel"

  children = carousel["children"].as_a
  children.size.should eq 2
  children[0].as_h["id"].should eq "child_1"
  children[1].as_h["id"].should eq "child_4"
end

# ==========================================================================
# Test: Posts with various missing fields
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": [
        {
          "id": "valid_001",
          "media_type": "IMAGE",
          "media_url": "https://scontent.cdninstagram.com/img1.jpg",
          "permalink": "https://instagram.com/p/valid001",
          "username": "testuser",
          "timestamp": "2024-01-15T10:30:00+0000"
        },
        {
          "media_type": "IMAGE",
          "media_url": "https://scontent.cdninstagram.com/img2.jpg"
        },
        {
          "id": "no_type",
          "media_url": "https://scontent.cdninstagram.com/img3.jpg"
        },
        {
          "id": "valid_002",
          "media_type": "VIDEO",
          "media_url": "https://scontent.cdninstagram.com/vid1.mp4",
          "thumbnail_url": "https://scontent.cdninstagram.com/thumb1.jpg",
          "permalink": "https://instagram.com/p/valid002",
          "username": "testuser",
          "timestamp": "2024-01-14T10:30:00+0000"
        }
      ]
    })
  end

  sleep 100.milliseconds

  # Should only have 2 valid slides
  slides = status[:slides].as_a
  slides.size.should eq 2
  slides[0].as_h["id"].should eq "valid_001"
  slides[1].as_h["id"].should eq "valid_002"
end

# ==========================================================================
# Test: Unknown media_type handling
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %({
      "data": [
        {
          "id": "valid_001",
          "media_type": "IMAGE",
          "media_url": "https://scontent.cdninstagram.com/img1.jpg",
          "permalink": "https://instagram.com/p/valid001",
          "username": "testuser",
          "timestamp": "2024-01-15T10:30:00+0000"
        },
        {
          "id": "unknown_001",
          "media_type": "STORY_MENTION",
          "media_url": "https://scontent.cdninstagram.com/story1.jpg",
          "permalink": "https://instagram.com/p/unknown001",
          "username": "testuser",
          "timestamp": "2024-01-14T10:30:00+0000"
        },
        {
          "id": "valid_002",
          "media_type": "VIDEO",
          "media_url": "https://scontent.cdninstagram.com/vid1.mp4",
          "permalink": "https://instagram.com/p/valid002",
          "username": "testuser",
          "timestamp": "2024-01-13T10:30:00+0000"
        }
      ]
    })
  end

  sleep 100.milliseconds

  # Unknown media types should be filtered out
  slides = status[:slides].as_a
  slides.size.should eq 2
  slides[0].as_h["id"].should eq "valid_001"
  slides[1].as_h["id"].should eq "valid_002"
end

# ==========================================================================
# Test: No access token configured
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "",
    token_expires_at:      0_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  sleep 100.milliseconds

  # Should set poll_state to no_token
  status[:poll_state].should eq "no_token"

  # Try to fetch feed
  retval = exec(:fetch_feed)
  sleep 100.milliseconds

  # Should still be no_token
  status[:poll_state].should eq "no_token"

  # Try to refresh token
  retval = exec(:refresh_token)
  sleep 100.milliseconds

  # Should set token_state to no_token
  status[:token_state].should eq "no_token"
end

# ==========================================================================
# Test: 500 Internal Server Error handling
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 500
    response << %({
      "error": {
        "message": "Internal Server Error",
        "type": "InternalServerError",
        "code": 500
      }
    })
  end

  sleep 100.milliseconds

  # Should mark as failed
  status[:poll_state].should eq "failed"
  error_info = status[:poll_error].as_h
  error_info["code"].as_i.should eq 500
end

# ==========================================================================
# Test: Rate limiting (429) handling
# ==========================================================================
DriverSpecs.mock_driver "Meta::Instagram" do
  settings({
    access_token:          "test_token",
    token_expires_at:      Time.utc.to_unix + 50.days.total_seconds.to_i64,
    poll_interval_minutes: 30,
    api_version:           "v25.0",
    media_limit:           25,
  })

  # Handle initial feed fetch
  expect_http_request do |request, response|
    response.status_code = 200
    response << %({"data": []})
  end

  sleep 100.milliseconds

  retval = exec(:fetch_feed)

  expect_http_request do |request, response|
    response.status_code = 429
    response << %({
      "error": {
        "message": "Rate limit exceeded",
        "type": "OAuthException",
        "code": 4
      }
    })
  end

  sleep 100.milliseconds

  # Should mark as failed
  status[:poll_state].should eq "failed"
  error_info = status[:poll_error].as_h
  error_info["code"].as_i.should eq 429
end
