# frozen_string_literal: true

module API::V2
  module Entities
    class Session < API::V2::Entities::Base
      expose :session_id,
             documentation: {
              type: 'String',
              desc: 'Session id'
             }

      expose :user_ip,
             documentation: {
              type: 'String',
              desc: 'Session ip'
             }

      expose :user_ip_country,
             documentation: {
              type: 'String',
              desc: 'Session ip country'
             }

      expose :user_agent,
             documentation: {
              type: 'String',
              desc: 'Session Browser Agent'
             }

      expose :current_session,
             documentation: {
              type: 'Boolean',
              desc: 'Is current session'
             }

      with_options(format_with: :iso_timestamp) do
        expose :authenticated_at
        expose :last_login_at
      end

    end
  end
end
