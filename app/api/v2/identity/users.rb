# frozen_string_literal: true

require_dependency 'barong/jwt'

module API::V2
  module Identity
    class Users < Grape::API
      helpers do
        def parse_refid!
          error!({ errors: ['identity.user.invalid_referral_format'] }, 422) unless params[:refid].start_with?(Barong::App.config.uid_prefix.upcase)
          user = User.find_by_uid(params[:refid])
          error!({ errors: ['identity.user.referral_doesnt_exist'] }, 422) if user.nil?

          user.id
        end
      end

      desc 'User related routes'
      resource :users do
        desc 'Creates new whitelist restriction',
        success: { code: 201, message: 'Creates new user' },
        failure: [
          { code: 400, message: 'Required params are missing' },
          { code: 422, message: 'Validation errors' }
        ]
        params do
          requires :whitelink_token,
                   type: String,
                   allow_blank: false
        end
        post '/access' do
          if Rails.cache.read(params[:whitelink_token]) == 'active'
            restriction = Restriction.new(
              category: 'whitelist',
              scope: 'ip',
              value: remote_ip,
              state: 'enabled'
            )

            code_error!(restriction.errors.details, 422) unless restriction.save
            Rails.cache.delete('restrictions')
          else
            error!({ errors: ['identity.user.access.invalid_token'] }, 422)
          end
        end

        desc 'Creates new user',
        success: { code: 201, message: 'Creates new user' },
        failure: [
          { code: 400, message: 'Required params are missing' },
          { code: 422, message: 'Validation errors' }
        ]
        params do
          requires :email,
                   type: String,
                   allow_blank: false,
                   desc: 'User Email'
          requires :password,
                   type: String,
                   allow_blank: false,
                   desc: 'User Password'
          optional :refid,
                   type: String,
                   desc: 'Referral uid'
          optional :captcha_response,
                   types: [String, Hash],
                   desc: 'Response from captcha widget'
          optional :data,
                   type: String,
                   desc: 'Any additional key: value pairs in json string format'
        end
        post do
          verify_captcha!(response: params['captcha_response'], endpoint: 'user_create')

          declared_params = declared(params, include_missing: false)
          user_params = declared_params.slice('email', 'password', 'data')

          user_params[:referral_id] = parse_refid! unless params[:refid].nil?

          user = User.new(user_params)

          code_error!(user.errors.details, 422) unless user.save

          activity_record(user: user.id, action: 'signup', result: 'succeed', topic: 'account')

          publish_confirmation_code(user, "register", 'system.user.email.confirmation.code')
          csrf_token = open_session(user)

          present user, with: API::V2::Entities::UserWithFullInfo, csrf_token: csrf_token
          status 201
        end

        desc 'Register Geetest captcha'
        get '/register_geetest' do
          CaptchaService::GeetestVerifier.new.register
        end

        namespace :email do
          desc 'Send confirmations instructions',
          success: { code: 201, message: 'Generated verification code' },
          failure: [
            { code: 400, message: 'Required params are missing' },
            { code: 422, message: 'Validation errors' }
          ]
          params do
            requires :email,
                     type: String,
                     allow_blank: false,
                     desc: 'Account email'
            optional :captcha_response,
                     types: [String, Hash],
                     desc: 'Response from captcha widget'
          end
          post '/generate_code' do
            verify_captcha!(response: params['captcha_response'], endpoint: 'email_confirmation')

            current_user = User.find_by_email(params[:email])

            if current_user.nil? || current_user.active?
              return status 201
            end

            publish_confirmation_code(current_user, "register", 'system.user.email.confirmation.code')
            status 201
          end

          desc 'Confirms an account',
          success: { code: 201, message: 'Confirms an account' },
          failure: [
            { code: 400, message: 'Required params are missing' },
            { code: 422, message: 'Validation errors' }
          ]
          params do
            requires :email,
                     type: String,
                     allow_blank: false,
                     desc: 'Account email'
            requires :code,
                     type: String,
                     allow_blank: false,
                     desc: 'Code from email'
          end
          post '/confirm_code' do
            current_user = User.find_by_email(params[:email])
            response = management_api_request("post", "http://applogic:3000/api/management/users/verify/get", { type: "register", email: current_user.email })

            error!({ errors: ['identity.user.code_doesnt_exist'] }, 422) unless response.code.to_i == 200
            applogic_code = JSON.parse(response.body.to_s)

            error!({ errors: ['identity.user.out_of_attempts'] }, 422) if applogic_code["attempts"] >= 3

            unless applogic_code["confirmation_code"] == params[:code]
              management_api_request("put", "http://applogic:3000/api/management/users/verify", { type: "register", email: current_user.email, attempts: applogic_code["attempts"] + 1 })

              error!({ errors: ['identity.user.code_incorrect'] }, 422)
            end

            management_api_request("put", "http://applogic:3000/api/management/users/verify", { type: "register", email: current_user.email, validated: true })

            if current_user.nil? || current_user.active?
              error!({ errors: ['identity.user.active_or_doesnt_exist'] }, 422)
            end

            current_user.labels.create!(key: 'email', value: 'verified', scope: 'private')

            csrf_token = open_session(current_user)

            EventAPI.notify('system.user.email.confirmed',
                            record: {
                              user: current_user.as_json_for_event_api,
                              domain: Barong::App.config.domain
                            })

            present current_user, with: API::V2::Entities::UserWithFullInfo, csrf_token: csrf_token
            status 201
          end
        end

        namespace :password do
          desc 'Send password reset instructions',
          success: { code: 201, message: 'Generated password reset code' },
          failure: [
            { code: 400, message: 'Required params are missing' },
            { code: 422, message: 'Validation errors' },
            { code: 404, message: 'User doesn\'t exist'}
          ]
          params do
            requires :email,
                     type: String,
                     message: 'identity.user.missing_email',
                     allow_blank: false,
                     desc: 'Account email'
            optional :captcha_response,
                     types: [String, Hash],
                     desc: 'Response from captcha widget'
          end

          post '/generate_code' do
            verify_captcha!(response: params['captcha_response'], endpoint: 'password_reset')

            current_user = User.find_by_email(params[:email])

            return status 201 if current_user.nil?

            activity_record(user: current_user.id, action: 'request password reset', result: 'succeed', topic: 'password')

            publish_confirmation_code(current_user, "reset_password", 'system.user.password.reset.code')
            status 201
          end

          desc 'Check reset password token',
          success: { code: 201, message: 'Check password reset code' },
          failure: [
            { code: 400, message: 'Required params are missing' },
            { code: 422, message: 'Validation errors' }
          ]
          params do
            requires :email,
                     type: String,
                     allow_blank: false,
                     desc: 'Account email'
            requires :code,
                     type: String,
                     allow_blank: false,
                     desc: 'Code from email'
          end
          post '/check_code' do
            current_user = User.find_by_email(params[:email])
            response = management_api_request("post", "http://applogic:3000/api/management/users/verify/get", { type: "reset_password", email: current_user.email })

            error!({ errors: ['identity.user.code_doesnt_exist'] }, 422) unless response.code.to_i == 200
            applogic_code = JSON.parse(response.body.to_s)

            error!({ errors: ['identity.user.out_of_attempts'] }, 422) if applogic_code["attempts"] >= 3

            unless applogic_code["confirmation_code"] == params[:code]
              management_api_request("put", "http://applogic:3000/api/management/users/verify", { type: "reset_password", email: current_user.email, attempts: applogic_code["attempts"] + 1 })

              error!({ errors: ['identity.user.code_incorrect'] }, 422)
            end

            status 201
          end

          desc 'Sets new account password',
          success: { code: 201, message: 'Resets password' },
          failure: [
            { code: 400, message: 'Required params are empty' },
            { code: 404, message: 'Record is not found' },
            { code: 422, message: 'Validation errors' }
          ]
          params do
            requires :email,
                     type: String,
                     allow_blank: false,
                     desc: 'Account email'
            requires :code,
                     type: String,
                     message: 'identity.user.missing_pass_token',
                     allow_blank: false,
                     desc: 'Token from email'
            requires :password,
                     type: String,
                     message: 'identity.user.missing_password',
                     allow_blank: false,
                     desc: 'User password'
            requires :confirm_password,
                     type: String,
                     message: 'identity.user.missing_confirm_password',
                     allow_blank: false,
                     desc: 'User password'
          end
          post '/confirm_code' do
            unless params[:password] == params[:confirm_password]
              error!({ errors: ['identity.user.passwords_doesnt_match'] }, 422)
            end

            current_user = User.find_by_email(params[:email])
            response = management_api_request("post", "http://applogic:3000/api/management/users/verify/get", { type: "reset_password", email: current_user.email })

            error!({ errors: ['identity.user.code_doesnt_exist'] }, 422) unless response.code.to_i == 200
            applogic_code = JSON.parse(response.body.to_s)

            error!({ errors: ['identity.user.out_of_attempts'] }, 422) if applogic_code["attempts"] >= 3

            unless applogic_code["confirmation_code"] == params[:code]
              management_api_request("put", "http://applogic:3000/api/management/users/verify", { type: "reset_password", email: current_user.email, attempts: applogic_code["attempts"] + 1 })

              error!({ errors: ['identity.user.code_incorrect'] }, 422)
            end

            management_api_request("put", "http://applogic:3000/api/management/users/verify", { type: "reset_password", email: current_user.email, validated: true })

            unless current_user.update(password: params[:password])
              error_note = { reason: current_user.errors.full_messages.to_sentence }.to_json
              activity_record(user: current_user.id, action: 'password reset',
                              result: 'failed', topic: 'password', data: error_note)
              code_error!(current_user.errors.details, 422)
            end

            activity_record(user: current_user.id, action: 'password reset', result: 'succeed', topic: 'password')

            EventAPI.notify('system.user.password.reset',
                            record: {
                              user: current_user.as_json_for_event_api,
                              domain: Barong::App.config.domain
                            })
            status 201
          end

        end
      end
    end
  end
end
