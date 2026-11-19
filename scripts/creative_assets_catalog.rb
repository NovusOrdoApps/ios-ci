# Shared knowledge about App Store "creative assets": the iOS 27 product page
# header (shown at the top of the product page on iOS/iPadOS 27+) and the
# search results artwork. Used by
#   - scripts/transform_creative_assets.rb  (local validation + normalisation)
#   - fastlane/Fastfile  lane update_creative_assets  (upload + placement
#     through the public App Store Connect API's App Asset Library)
#
# Sources: Apple's App Store Connect OpenAPI spec (4.6.1, AppAssetLibrary*
# schemas, PlacementType enum) and Apple's "Placing assets on your App Store
# surfaces" guide. Pixel sizes are Apple's creative asset specifications.
module CreativeAssetsCatalog
  # File stem under metadata/CreativeAssets/{defaults,<locale>}/ => placement.
  #   exact:  the single accepted size; files within TOLERANCE px are scaled to it
  #   aspect/min/max: a size range (kept as-is, never scaled)
  KINDS = {
    "product_page_header" => {
      placement_type: "PRODUCT_PAGE_HEADER_ASSET",
      exact: [3840, 1646], # 21:9; safe area 1646x661 at (1097, 493)
      label: "Product page header",
    },
    "search_results" => {
      placement_type: "APP_STORE_SEARCH_RESULTS_ASSET",
      aspect: 3.0 / 2.0,
      min: [1920, 1280],
      max: [3840, 2560],
      label: "Search results artwork",
    },
  }.freeze

  EXTENSIONS = %w[png jpg jpeg].freeze
  TOLERANCE = 20          # px, same as screenshots
  ASPECT_TOLERANCE = 0.01 # 1% for range-type assets
  CATEGORY = "CREATIVE_ASSETS"
  FEATURE = "APP_STORE_VERSIONS"
  DEFAULTS_DIR = "defaults"

  def self.placement_types
    KINDS.values.map { |k| k[:placement_type] }
  end

  # "product_page_header.png" => "product_page_header"; nil when the name is
  # not a known kind with an accepted extension.
  def self.kind_for_filename(basename)
    ext = File.extname(basename).delete_prefix(".").downcase
    stem = File.basename(basename, File.extname(basename))
    return nil unless EXTENSIONS.include?(ext) && KINDS.key?(stem)
    stem
  end

  # => { ok: true, target: [w, h] } or { ok: false, message: "..." }
  def self.check_dimensions(kind, width, height)
    spec = KINDS.fetch(kind)
    if spec[:exact]
      tw, th = spec[:exact]
      dw = (width - tw).abs
      dh = (height - th).abs
      return { ok: true, target: [tw, th] } if dw <= TOLERANCE && dh <= TOLERANCE
      return { ok: false, message: "must be #{tw}x#{th} (within #{TOLERANCE}px); got #{width}x#{height}" }
    end

    ratio = width.to_f / height
    unless (ratio - spec[:aspect]).abs <= spec[:aspect] * ASPECT_TOLERANCE
      return { ok: false, message: "aspect must be 3:2; got #{width}x#{height} (#{ratio.round(3)})" }
    end
    minw, minh = spec[:min]
    maxw, maxh = spec[:max]
    unless width.between?(minw, maxw) && height.between?(minh, maxh)
      return { ok: false, message: "must be between #{minw}x#{minh} and #{maxw}x#{maxh}; got #{width}x#{height}" }
    end
    { ok: true, target: [width, height] }
  end

  # Placement groups a placement type may use on App Store versions, read from
  # the body of GET /v1/appAssetLibraryRefData. Apple: group ids are catalog
  # data, not an enumeration, so never hard-code them.
  # => [{ "group" => "SOME_PROFILE" or nil, "max" => 1 }]  (empty when unlisted)
  def self.placement_groups(ref_body, placement_type)
    out = []
    Array(ref_body["data"]).each do |datum|
      Array(datum.dig("attributes", "features")).each do |feat|
        next unless feat["featureId"] == FEATURE
        Array(feat["placementPolicies"]).each do |pol|
          next unless pol["placementType"] == placement_type
          Array(pol["groupLimits"]).each do |gl|
            ids = Array(gl["groupIds"])
            if ids.empty?
              out << { "group" => nil, "max" => gl["maxCount"] }
            else
              ids.each { |g| out << { "group" => g, "max" => gl["maxCount"] } }
            end
          end
        end
      end
    end
    out.uniq
  end

  # Decide what to do with one locale's existing placements of one type.
  #   existing:      placement resources as returned by the API (hashes)
  #   want_image_id: the library image the repo wants there; nil = repo has no file
  #   groups:        [{ "group" => id_or_nil, ... }] from placement_groups (or [{nil}])
  # => { keep: [placement], delete: [placement], create: [group_or_nil, ...] }
  # A placement is kept only when it sits in a listed group AND already points
  # at want_image_id; everything else of that type goes, including placements in
  # groups the catalog no longer lists.
  def self.reconcile_plan(existing, want_image_id, groups)
    existing = Array(existing)
    return { keep: [], delete: existing.dup, create: [] } if want_image_id.nil?

    keep = []
    delete = []
    create = []
    handled = []
    groups.each do |g|
      group = g["group"]
      same = existing.select { |p| group.nil? || p.dig("attributes", "placementGroup") == group }
      handled.concat(same)
      match = same.find { |p| p.dig("relationships", "image", "data", "id") == want_image_id }
      if match
        keep << match
      else
        create << group
      end
      delete.concat(same - [match].compact)
    end
    delete.concat(existing - handled)
    { keep: keep, delete: delete.uniq, create: create }
  end

  # specIds the catalog associates with a placement type (any group), from
  # placementTypes[].specMappings[].specs and imageSpecs[].compatiblePlacementTypes.
  def self.spec_ids(ref_body, placement_type)
    ids = []
    Array(ref_body["data"]).each do |datum|
      Array(datum.dig("attributes", "placementTypes")).each do |pt|
        next unless pt["placementTypeId"] == placement_type
        Array(pt["specMappings"]).each do |m|
          Array(m["specs"]).each { |s| ids << (s.is_a?(Hash) ? (s["specId"] || s["id"]) : s) }
        end
      end
      Array(datum.dig("attributes", "imageSpecs")).each do |s|
        ids << s["specId"] if Array(s["compatiblePlacementTypes"]).include?(placement_type)
      end
    end
    ids.compact.map(&:to_s).uniq
  end
end
