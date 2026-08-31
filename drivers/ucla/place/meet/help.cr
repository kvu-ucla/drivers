# UCLA-maintained copy of drivers/place/meet/help.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
require "json"

module Place
  struct HelpPage
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter icon : String?
    getter title : String
    getter content : String
  end

  alias Help = Hash(String, HelpPage)
end
