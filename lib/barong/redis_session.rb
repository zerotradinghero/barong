# frozen_string_literal: true

module Barong
  class RedisSession
    def self.hexdigest_session(session_id)
      Digest::SHA256.hexdigest(session_id.to_s)
    end

    # We have session stored in redis
    # Like _session_id:2::value
    def self.encrypted_session(session_id)
      "_session_id:2::#{hexdigest_session(session_id)}"
    end

    def self.add(user_uid, session, expire_time)
      key = key_name(user_uid, session.id)
      Rails.cache.fetch(key, expires_in: expire_time) {
        session.merge!(
          "session_id": session.id.to_s,
          "encrypted": encrypted_session(session.id)
        ).to_h.to_json
      }
    end

    def self.get(user_uid, session_id)
      key = key_name(user_uid, session_id)
      Rails.cache.read(key)
    end

    def self.delete(user_uid, session_id)
      key = key_name(user_uid, session_id)
      value = Rails.cache.read(key)
      Rails.cache.delete(value)
      Rails.cache.delete(key)
    end

    def self.update(user_uid, session, expire_time)
      key = key_name(user_uid, session.id)
      value = session.merge!(
        "session_id": session.id.to_s,
        "encrypted": encrypted_session(session.id),
        "last_login_at": Time.now,
      ).to_h.to_json
      Rails.cache.write(key, value, expires_in: expire_time)
    end

    def self.get_all(user_uid)
      sessions = []
      session_keys = Rails.cache.redis.keys("#{user_uid}_session_*")
      session_keys.each do |key|
        value = Rails.cache.read(key)
        value_parsed = JSON.parse(value)
        expire_time = value_parsed["expire_time"].to_i

        if expire_time > Time.now.to_i
          session = {
            session_id: value_parsed["session_id"],
            user_ip: value_parsed["user_ip"],
            user_ip_country: value_parsed["user_ip_country"],
            user_agent: value_parsed["user_agent"],
            authenticated_at: Time.parse(value_parsed["authenticated_at"]).utc,
            last_login_at: Time.parse(value_parsed["last_login_at"]).utc,
          }
  
          sessions.push(session)
        else
          Rails.cache.delete(value)
          Rails.cache.delete(key)
        end
      end

      sessions
    end

    def self.invalidate_all(user_uid, session_id = nil)
      # Get list of active user sessions
      session_keys = Rails.cache.redis.keys("#{user_uid}_session_*")

      # Delete user sessions from native session list
      # If session ID present
      # system should invalidate all session except this session ID
      key_name = key_name(user_uid, session_id)
      session_keys.delete_if {|s_key| s_key == key_name }.each do |key|
        # Read value from additional redis list
        value = Rails.cache.read(key)
        # Delete session from native redis list
        Rails.cache.delete(value)
      end

      # Delete list of all user sessions from additinal redis list
      session_keys.each do |key|
        Rails.cache.delete(key)
      end
    end

    def self.key_name(user_uid, session_id)
      if session_id.present?
        hsid = hexdigest_session(session_id)
        "#{user_uid}_session_#{hsid}"
      end
    end
  end
end
