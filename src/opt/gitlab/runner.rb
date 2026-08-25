class X509AuthAgent
	def call(env)
		req = Rack::Request.new(env)
		
		case req.path_info
		when '/check_user'
			username = req.params['username'])
			return [400, {}, ["error: missing params"]] unless username.is_a? String
			if User.exists?(username)
				return [200, "success: user exists"]
			else
				return [404, "success: user not found"]
			end
		when '/create_user'
			success, message = create_user(
				req.params['username'],
				req.params['display_name'],
				req.params['email'],
				req.params['admin'])
			[(success ? 200 : 400), {}, [message]]
		else
			[400, {}, ['invalid action']]
		end
	end

	private
	def create_user(username, display_name, email, admin=false)
		return [false, "error: missing params"] unless username and display_name and email
		return [false, "error: username already exists"] if User.exists?(username: username)
		return [false, "error: display_name already exists"] if User.exists?(name: display_name)
		return [false, "error: email already exists"] if User.exists?(email: email)
		pass = SecureRandom.hex
		Gitlab::Redis::SharedState.store.set("x509auth:#{username}:password", pass)
		u = User.new(username: username, email: email, name: display_name, password: pass, password_confirmation: pass, admin: (admin.to_s == 'true'))
		u.assign_personal_namespace(Organizations::Organization.first)
		u.skip_confirmation!
		u.save!
		return [true, "success: user created"]
	end
end

Rack::Server.new(app: X509AuthAgent.new, Host: '/var/opt/gitlab/gitlab-rails/sockets/runner.socket').start
