qs = require('querystring')
fs = require('fs')
_ = require('lodash')
Promise = require('bluebird')
request = require('request')
Bunyan  = require('bunyan')
bformat  = require('bunyan-format')

class SeaweedFS

  constructor: (@config = {}, @logger) ->
    _.defaults(@config, {
      masters: [
        {
          host: 'localhost'
          port: 9333
        }
      ]
      scheme: 'http'
      retry_count: 60
      retry_timeout: 2000 #ms
      log_name: 'SeaweedFS'
      log_level: 'info'
    })
    if not @logger?
      @logger = new Bunyan({
        name: @config.log_name,
        streams: [
          {
            level: @config.log_level,
            stream: bformat({ outputMode: 'short' })
          }
        ]
      })
    @active_masters = _.cloneDeep(_.sortByAll(@config.masters, ['host', 'port']))
    @Promise = Promise
    return

  makeMasterRequest: (options = {}) ->
    options.uri = "#{@address}#{options.path}"
    @logger.debug options, "Making request to master"
    @_makeRequest(options)
    .catch (err) =>
      ###*
        Normally the server is supposed to send json responses but when it doesn't send a json response then
        that means that the server is warming up and has just now become the leader and is waiting to connect
        to the volumes this means that requests like /dir/assign will fail but /cluster/status will pass
        so we need to wait it out till the server warms up so we add a delay time out for that particlular
        request so that it doesn't fail
      ###
      if _.contains(err.message, 'Unexpected content-type')
        @_makeMasterRequest(options)
      else if _.contains(err.message, 'ECONNREFUSED')
        @connect()
        .then =>
          @makeMasterRequest(options)
      else
        Promise.reject(err)

  _makeMasterRequest: (options = {}) ->
    options = _.defaults(options, {
      retry_count: @config.retry_count,
      retry_timeout: @config.retry_timeout
    })
    Promise.delay(options.retry_timeout)
    .then =>
      if options.retry_count is 0
        return Promise.reject(new Error("Failed request to #{options.uri}"))
      else
        @logger.debug options, 'Retrying request to master'
        options.retry_count -= 1
        @makeMasterRequest(options)


  makeVolumeRequest: (options = {}) ->
    {file_id, preferred_location, request_options} = options
    @find(file_id)
    .then (locations) =>
      if locations.length > 0
        if preferred_location?
          locations.unshift("#{@config.scheme}://#{preferred_location}/#{file_id}")
        Promise.reduce(locations, (result, location) =>
          if result.success
            Promise.resolve(result)
          else
            request_options.uri = location
            @logger.debug _.pick(request_options, 'method', 'uri'), "Making request to volume"
            @_makeRequest(request_options)
            .then (response) ->
              result.success = true
              result.value = response
              Promise.resolve(result)
            .catch (err) ->
              result.errors ?= {}
              result.errors[location] = { is_error: true, message: err.message }
              Promise.resolve(result)
        , { success: false })
        .then ({ value, errors }) ->
          if value? or request_options.stream?
            Promise.resolve(value)
          else
            Promise.reject(new Error("Unable to perform file operations on '#{file_id}': #{JSON.stringify(errors)}"))
      else
        Promise.reject(new Error("File location for '#{file_id}' not found"))

  _makeRequest: (options = {}) ->
    options.full_response ?= false
    new Promise (resolve, reject) =>
      if options.stream?
        @logger.debug _.pick(options, 'uri'), "Streaming file"
        request(options.uri)
        .on 'response', (response) =>
          resolve()
        .on 'error', (err) ->
          reject(err)
        .pipe(options.stream)
      else
        if (file = options.formData?.file)?
          if not (file instanceof Buffer)
            file = fs.createReadStream(file)
            file.on 'error', (err) =>
              reject(err)
            options.formData.file = file
        request(options, (err, response) =>
          if err then reject(err)
          else if options.full_response
            resolve(response)
          else
            if /application\/json/.test(response.headers['content-type'])
              resolve(JSON.parse(response.body))
            else
              try
                resolve(JSON.parse(response.body))
              catch err
                reject(new Error("Unexpected content-type '#{response.headers['content-type']}' in response from #{options.uri}"))
        )

  connect: ->
    @_connect(0, @config.retry_count)

  _connect: (master_index, retry_count) ->
    @logger.debug { master_index: master_index, active_masters: @active_masters }, "Connecting to master"
    if (master = @active_masters[master_index])?
      @address = "#{@config.scheme}://#{master.host}:#{master.port}"
      @_makeRequest({ uri: "#{@address}/cluster/status" })
      .then (status) =>
        @logger.debug "Connected to master #{@address}"
        Promise.resolve()
      .catch (err) =>
        @logger.debug "Error connecting to master #{@address}"
        @_connect(master_index + 1, retry_count)
    else
      Promise.delay(@config.retry_timeout)
      .then =>
        if retry_count is 0
          return Promise.reject(new Error('Could not connect to any nodes'))
        else
          @logger.debug retry_count, 'Retrying connection to master'
          @_connect(0, retry_count - 1)

  clusterStatus: ->
    @logger.trace 'Getting cluster status'
    @makeMasterRequest({ path: "/cluster/status" })

  find: (file_id) ->
    @logger.trace file_id, 'Finding'
    unless /^\d+,[a-zA-Z0-9_]+$/.test(file_id)
      return Promise.reject new Error("File '#{file_id}' is not a valid file_id")
    [volume] = file_id.split(',')
    @makeMasterRequest({ path: "/dir/lookup?volumeId=#{volume}" })
    .then (result) =>
      locations = []
      if result.locations?
        for location in result.locations
          locations.push "#{@config.scheme}://#{location.publicUrl}/#{file_id}"
      Promise.resolve(locations)

  read: (file_id, stream, options = {}) ->
    @logger.trace file_id, 'Reading'
    {preferred_location} = options
    @makeVolumeRequest({
      file_id: file_id,
      preferred_location: preferred_location,
      request_options: {
        stream: stream,
        method: 'GET',
        encoding: null,
        full_response: true
      }
    })
    .then (response) =>
      if stream?
        Promise.resolve()
      else
        if response.statusCode is 404
          Promise.reject(new Error("file '#{file_id}' not found"))
        else
          Promise.resolve(response.body)

  assign: (files, options = {}) ->
    @logger.trace options, 'Assigning'
    options = _.defaults(options, {
      retry_count: @config.retry_count,
      retry_timeout: @config.retry_timeout
    })
    @makeMasterRequest({ path: "/dir/assign?#{qs.stringify({ count: files.length })}" }) # This mutates the options uri so that the next class will have the uri with them
    .then (response) =>
      if response.error? and options.retry_count > 0
        options.retry_count -= 1
        Promise.delay(options.retry_timeout)
        .then =>
          @assign(files, options)
      else
        Promise.resolve(response)
    .catch (err) =>
      if _.contains(err.message, 'Unexpected content-type') and options.retry_count > 0
        options.retry_count -= 1
        Promise.delay(options.retry_timeout)
        .then =>
          @assign(files, options)
      else
        Promise.reject(err)

  write: (files) ->
    @logger.trace files, 'Writing'
    if not _.isArray(files)
      files = [files]
    is_error = false
    results = []
    @assign(files)
    .then (file_info) =>
      current = Promise.cast()
      _.forEach files, (file, index) =>
        current = current.then =>
          if parseInt(index) is 0
            file_id = file_info.fid
          else
            file_id = "#{file_info.fid}_#{index}"
          @makeVolumeRequest({
            file_id: file_id
            request_options: {
              method: 'POST'
              formData: { file: file }
            }
          })
          .then (result) ->
            results.push result
          .catch (err) ->
            is_error = true
            results.push { is_error: true, message: err.message }
      current
      .then ->
        if is_error or results.length isnt files.length
          Promise.reject(new Error("An error occured while upload files: #{JSON.stringify(results)}"))
        else
          Promise.resolve(file_info, results)


  remove: (file_id) ->
    @logger.trace file_id, 'Removing'
    @makeVolumeRequest({
      file_id: file_id,
      request_options: {
        method: 'DELETE',
        full_response: true
      }
    })
    .then (response) =>
      if response.statusCode is 404
        Promise.reject(new Error("file '#{file_id}' not found"))
      else
        Promise.resolve(JSON.parse(response.body))

module.exports = SeaweedFS
