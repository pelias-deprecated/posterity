module Pelias
  class QuattroIndexer

    include Sidekiq::Worker

    PATHS = {
      admin0: 'qs_adm0',
      admin1: 'qs_adm1',
      admin2: 'qs_adm2',
      local_admin: 'qs_localadmin',
      locality: 'gn-qs_localities',
      neighborhood: 'qs_neighborhoods'
    }

    ABBR_FIELDS = {
      admin0: :qs_iso_cc
    }

    NAME_FIELDS = {
      admin0: :qs_a0,
      admin1: :qs_a1,
      admin2: :qs_a2,
      local_admin: :qs_la,
      locality: :qs_loc,
      neighborhood: :name
    }

    SHAPE_ORDER = [:admin0, :admin1, :admin2, :local_admin, :locality, :neighborhood, :street, :address, :poi]

    def perform(type, gid)

      type_sym = type.to_sym

      fields = []
      fields << (type_sym == :neighborhood ? :gn_id___qs_gn_id   : :qs_gn_id)
      fields << (type_sym == :neighborhood ? :woe_id___qs_woe_id : :qs_woe_id)
      fields << Sequel.function('st_astext', Sequel.function('st_centroid', :geom)).as('st_centroid')
      fields << NAME_FIELDS[type_sym]
      fields << ABBR_FIELDS[type_sym] if ABBR_FIELDS.key?(type_sym)
      fields << :qs_iso_cc if type_sym == :admin1
      record = DB[:"qs_#{type}"].select(*fields).where(gid: gid).first

      # grab our ids
      gn_id = sti record[:qs_gn_id]
      woe_id = sti record[:qs_woe_id]

      # Build a set
      set = Pelias::LocationSet.new
      set.append_records "#{type}.gn_id", gn_id
      set.append_records "#{type}.woe_id", woe_id
      set.close_records_for type

      # Update it
      parent_types = self.class.parent_types_for(type_sym)
      set.update do |_id, entry|

        _id ||= "qs:#{type}:#{gid}"
        entry['_id'] = _id

        # Data about this particular one
        entry['name'] = record[NAME_FIELDS[type_sym]]
        entry['abbr'] = record[ABBR_FIELDS[type_sym]] if ABBR_FIELDS.key?(type_sym)
        entry['abbr'] = self.class.state_map.key(entry['name']) if type_sym == :admin1 && record[:qs_iso_cc] == 'US'
        entry['gn_id'] = gn_id
        entry['woe_id'] = woe_id
        entry['center_point'] = parse_point record[:st_centroid]

        # Use GN data if we have it
        if gn_id && gn_raw = Pelias::REDIS.hget('geoname', gn_id)
          gn_data = JSON.parse(gn_raw)
          entry['name'] = gn_data['name']
          entry['alternate_names'] = gn_data['alternate_names'] || []
          entry['population'] = gn_data['population'].to_i
        end

        # Copy down for the level
        entry['refs'] ||= {}
        entry['refs'][type] = _id
        entry["#{type}_name"] = entry['name']
        entry["#{type}_abbr"] = entry['abbr']
        entry["#{type}_alternate_names"] = entry['alternate_names']

        # And look up the parents
        set.grab_parents(parent_types, entry)

      end

      # And save
      set.finalize!

    end

    private

    # convert a point to es format
    def parse_point(point_data)
      point_data.gsub(/[^-\d\. ]/, '').split(' ').map(&:to_f)
    end

    def sti(n)
      if n
        n_i = n.to_i
        n_i if n_i > 0
      end
    end

    def self.state_map
      @states ||= YAML.load_file 'config/us_states.yml'
    end

    def self.parent_types_for(type)
      SHAPE_ORDER[0...SHAPE_ORDER.index(type)]
    end

  end
end
