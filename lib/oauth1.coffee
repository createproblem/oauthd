# oauthd
# http://oauth.io
#
# Copyright (c) 2013 thyb, bump
# Licensed under the MIT license.

querystring = require 'querystring'
crypto = require 'crypto'

async = require 'async'
request = require 'request'

check = require './check'
db = require './db'
dbstates = require './db_states'
dbproviders = require './db_providers'
dbapps = require './db_apps'
config = require './config'

OAuth1ResponseParser = require './oauth1-response-parser'
OAuthBase = require './oauth-base'

class OAuth1 extends OAuthBase
	constructor: (provider) ->
		super 'oauth1', provider

	authorize: (parameters, opts, callback) ->
		@_setParams @_provider.parameters
		@_setParams @_provider.oauth1.parameters
		@_createState @_provider, opts, (err, state) =>
			return callback err if err
			@_getRequestToken state, parameters, opts, callback

	_getRequestToken: (state, parameters, opts, callback) ->
		request_token = @_provider.oauth1.request_token
		query = {}
		if typeof opts.options?.request_token == 'object'
			query = opts.options.request_token
		for name, value of request_token.query
			param = @_replaceParam value, state:state.id, callback:config.host_url+config.relbase, parameters
			query[name] = param if param
		headers = {}
		headers["Accept"] = @_short_formats[request_token.format] || request_token.format if request_token.format
		for name, value of request_token.headers
			param = @_replaceParam value, {}, parameters
			headers[name] = param if param
		options =
			url: request_token.url
			method: request_token.method?.toUpperCase() || "POST"
			encoding: null
			oauth:
				callback: query.oauth_callback
				consumer_key: parameters.client_id
				consumer_secret: parameters.client_secret
		delete query.oauth_callback
		options.headers = headers if Object.keys(headers).length
		if options.method == 'POST'
			options.form = query
		else
			options.qs = query

		# do request to request_token
		request options, (err, response, body) =>
			return callback err if err
			@_parseGetRequestTokenResponse(response, body, parameters, opts, headers, state, callback)

	_parseGetRequestTokenResponse: (response, body, parameters, opts, headers, state, callback) ->
		responseParser = new OAuth1ResponseParser(response, body, headers["Accept"], 'request_token')
		responseParser.parse (err, response) =>
			return callback err if err

			dbstates.setToken state.id, response.oauth_token_secret, (err, returnCode) =>
				return callback err if err
				callback null, @_generateRequestTokenAuthorizeUrl(state, parameters, opts, response)

	_generateRequestTokenAuthorizeUrl: (state, parameters, opts, response) ->
		authorize = @_provider.oauth1.authorize
		query = {}
		if typeof opts.options?.authorize == 'object'
			query = opts.options.authorize
		for name, value of authorize.query
			param = @_replaceParam value, state:state.id, callback:config.host_url+config.relbase, parameters
			query[name] = param if param
		query.oauth_token = response.oauth_token
		url = @_replaceParam authorize.url, {}, parameters
		url += "?" + querystring.stringify query
		return url:url, state:state.id

	access_token: (state, req, callback) ->
		if not req.params.oauth_token && not req.params.error
			req.params.error_description ?= 'Authorization refused'

		# manage errors in callback
		if req.params.error || req.params.error_description
			err = new check.Error
			err.error req.params.error_description || 'Error while authorizing'
			err.body.error = req.params.error if req.params.error
			err.body.error_uri = req.params.error_uri if req.params.error_uri
			return callback err

		# get infos from state
		dbapps.getKeyset state.key, state.provider, (err, keyset) =>
			return callback err if err
			parameters = keyset.parameters
			err = new check.Error
			if @_provider.oauth1.authorize.ignore_verifier == true
				err.check req.params, oauth_token:'string'
			else
				err.check req.params, oauth_token:'string', oauth_verifier:'string'
			return callback err if err.failed()
			@_setParams @_provider.parameters
			@_setParams @_provider.oauth1.parameters

			access_token = @_provider.oauth1.access_token
			query = {}
			hard_params = state:state.id, callback:config.host_url+config.relbase
			for extra in (@_provider.oauth1.authorize.extra || [])
				hard_params[extra] = req.params[extra] if req.params[extra]
			for name, value of access_token.query
				param = @_replaceParam value, hard_params, parameters
				query[name] = param if param
			headers = {}
			headers["Accept"] = @_short_formats[access_token.format] || access_token.format if access_token.format
			for name, value of access_token.headers
				param = @_replaceParam value, {}, parameters
				headers[name] = param if param
			options =
				url: @_replaceParam access_token.url, hard_params, parameters
				method: access_token.method?.toUpperCase() || "POST"
				oauth:
					callback: query.oauth_callback
					consumer_key: parameters.client_id
					consumer_secret: parameters.client_secret
					token: req.params.oauth_token
					token_secret: state.token
			if @_provider.oauth1.authorize.ignore_verifier != true
				options.oauth.verifier = req.params.oauth_verifier
			else
				options.oauth.verifier = ""
			delete query.oauth_callback

			options.headers = headers if Object.keys(headers).length
			if options.method == 'POST'
				options.form = query
			else
				options.qs = query

			# do request to access_token
			request options, (e, r, body) =>
				return callback(e) if e
				responseParser = new OAuth1ResponseParser(r, body, headers["Accept"], 'access_token')
				responseParser.parse (err, response) =>
					return callback err if err

					expire = response.body.expire
					expire ?= response.body.expires
					expire ?= response.body.expires_in
					expire ?= response.body.expires_at
					if expire
						expire = parseInt expire
						now = (new Date).getTime()
						expire -= now if expire > now
					requestclone = {}
					requestclone[k] = v for k, v of @_provider.oauth1.request
					for k, v of @_params
						if v.scope == 'public'
							requestclone.parameters ?= {}
							requestclone.parameters[k] = parameters[k]
					result =
						oauth_token: response.oauth_token
						oauth_token_secret: response.oauth_token_secret
						expires_in: expire
						request: requestclone
					for extra in (access_token.extra||[])
						result[extra] = response.body[extra] if response.body[extra]
					for extra in (@_provider.oauth1.authorize.extra||[])
						result[extra] = req.params[extra] if req.params[extra]
					callback null, result

	request: (parameters, req, callback) ->
		@_setParams @_provider.parameters
		@_setParams @_provider.oauth1.parameters

		if ! parameters.oauthio.oauth_token || ! parameters.oauthio.oauth_token_secret
			return callback new check.Error "You must provide 'oauth_token' and 'oauth_token_secret' in 'oauthio' http header"

		oauthrequest = @_provider.oauth1.request

		options =
			method: req.method
			followAllRedirects: true

		# build url
		options.url = req.apiUrl
		if typeof req.query == 'function' and typeof req.query() == 'string'
			options.url += "?" + req.query()
		if ! options.url.match(/^[a-z]{2,16}:\/\//)
			if options.url[0] != '/'
				options.url = '/' + options.url
			options.url = oauthrequest.url + options.url
		options.url = @_replaceParam options.url, parameters.oauthio, parameters

		# build query
		options.qs = {}
		for name, value of oauthrequest.query
			param = @_replaceParam value, parameters.oauthio, parameters
			options.qs[name] = param if param

		options.oauth =
			consumer_key: parameters.client_id
			consumer_secret: parameters.client_secret
			token: parameters.oauthio.oauth_token
			token_secret: parameters.oauthio.oauth_token_secret

		# build headers
		ignoreheaders = [
			'oauthio', 'host', 'connection',
			'origin', 'referer'
		]

		options.headers = {}
		for k, v of req.headers
			if ignoreheaders.indexOf(k) == -1
				k = k.replace /\b[a-z]/g, (-> arguments[0].toUpperCase())
				options.headers[k] = v

		for name, value of oauthrequest.headers
			param = @_replaceParam value, parameters.oauthio, parameters
			options.headers[name] = param if param

		# do request
		callback null, options

module.exports = OAuth1
