require('shelljs/global')
child_process = require('child_process')
SeaweedFS = require('../src/seaweedfs')
_ = require('lodash')
Promise = require('bluebird')
os = require('os')
global.chai = require 'chai'
global.should = chai.should()
global.expect = chai.expect

workers = []
killWorkers = (signal) ->
  () ->
    for worker in workers
      worker.kill()
      # process.kill(parseInt(pid), signal)

process.on("uncaughtException", killWorkers)
process.on("SIGINT", killWorkers('SIGINT'))
process.on("SIGTERM", killWorkers('SIGTERM'))
process.on('exit', killWorkers('SIGTERM'))

global.spawn = (args...) ->
  new Promise (resolve, reject) ->
    ps = child_process.spawn(args...)
    # if ps.stdout?
    #   ps.stdout.pipe(process.stdout)
    # if ps.stderr?
    #   ps.stderr.pipe(process.stderr)
    ps.on('error', (err) ->
      reject(err)
    )
    Promise.delay(2000)
    .then ->
      resolve(ps)

before (next) ->
  @timeout(60000)
  @ws = new SeaweedFS({
    masters: [
      {
        host: 'localhost'
        port: 9333
      }
      {
        host: 'localhost'
        port: 9334
      }
      {
        host: 'localhost'
        port: 9335
      }
    ]
    log_level: 'debug'
  })
  tmp = os.tmpDir()
  fs = require('fs')
  targz = require('tar.gz')
  request = require('request')
  deferred = Promise.defer()
  if not fs.existsSync('./weed')
    console.log 'Downloading Weedfs Binary'
    file_stream = targz().createWriteStream(process.cwd())
    request.get('http://bintray.com/artifact/download/chrislusf/seaweedfs/weed_0.70beta_linux_amd64.tar.gz')
    .pipe(file_stream)
    .on('finish', ->
      file_stream.end()
      Promise.delay(5000)
      .then ->
        mv 'weed_0.70beta_linux_amd64/weed', process.cwd()
        chmod '+x', 'weed'
        rm '-rf', 'weed_0.70beta_linux_amd64/'
        deferred.resolve()
    )
  else
    deferred.resolve()
  deferred.promise
  .then =>
    rm "./image.txt"
    rm '-rf', "#{tmp}/1", "#{tmp}/2", "#{tmp}/3", "#{tmp}/m1", "#{tmp}/m2", "#{tmp}/m3"
    mkdir "#{tmp}/1", "#{tmp}/2", "#{tmp}/3", "#{tmp}/m1", "#{tmp}/m2", "#{tmp}/m3"
    spawn('./weed', ['master' ,'-port=9333', '-defaultReplication=010', "-mdir=#{tmp}/m1"])
  .then (ps) =>
    @m1 = ps
    workers.push ps
    spawn('./weed', ['master', '-port=9334', '-defaultReplication=010', '-peers=localhost:9333', "-mdir=#{tmp}/m2"])
  .then (ps) =>
    @m2 = ps
    workers.push ps
    spawn('./weed', ['master', '-port=9335', '-defaultReplication=010', '-peers=localhost:9333', "-mdir=#{tmp}/m3"])
  .then (ps) =>
    @m3 = ps
    workers.push ps
    spawn('./weed', ['volume', '-port=8080', "-dir=#{tmp}/1", '-max=2', '-rack=r1', '-dataCenter=dc1', '-mserver=localhost:9333'])
  .then (ps) =>
    @v1 = ps
    workers.push ps
    spawn('./weed', ['volume', '-port=8081', "-dir=#{tmp}/2", '-max=2', '-rack=r2', '-dataCenter=dc1', '-mserver=localhost:9333'])
  .then (ps) =>
    @v2 = ps
    workers.push ps
    spawn('./weed', ['volume', '-port=8082', "-dir=#{tmp}/3", '-max=2', '-rack=r3', '-dataCenter=dc1', '-mserver=localhost:9333'])
  .then (ps) =>
    @v3 = ps
    workers.push ps
    @ws.connect()
  .then ->
    next()

describe 'Weedfs Client in a broken Cluster', ->

  it 'should kill the active master', (next) ->
    @m1.kill()
    @v1.kill()
    @ws.clusterStatus()
    .then (status) ->
      next()

describe 'Weedfs client', ->

  describe 'Connecting to the master', (next) ->

    it 'should fail trying to connect to a cluster', (next) ->
      fs = new SeaweedFS({
        masters: [
          {
            host: 'localhost'
            port: 9338
          }
          {
            host: 'localhost'
            port: 9339
          }
          {
            host: 'localhost'
            port: 9337
          }
        ]
        scheme: 'http'
        retry_count: 10
        retry_timeout: 10
      })
      fs.connect()
      .catch (err) ->
        err.message.should.equal 'Could not connect to any nodes'
        next()

    it 'makes operations on a dead cluster', (next) ->
      fs = new SeaweedFS({
        masters: [
          {
            host: 'localhost'
            port: 9338
          }
          {
            host: 'localhost'
            port: 9339
          }
          {
            host: 'localhost'
            port: 9337
          }
        ]
        scheme: 'http'
        retry_count: 10
        retry_timeout: 10
      })
      fs.connect()
      .catch (err) ->
        err.message.should.equal 'Could not connect to any nodes'
        fs.clusterStatus()
      .catch (err) ->
        err.message.should.equal 'Could not connect to any nodes'
        fs.write(new Buffer('Test This'))
      .catch (err) ->
        err.message.should.equal 'Could not connect to any nodes'
        next()

    it 'should get the cluster status', (next) ->
      @ws.clusterStatus()
      .then (status) ->
        status.Leader.should.exist
        next()

  describe 'Find', ->

    it 'should throw error when passing in wrong fid', (next) ->
      @ws.find('test_string')
      .catch (err) =>
        err.message.should.equal "File 'test_string' is not a valid file_id"
        next()

    it 'should find an id', (next) ->
      @ws.write(new Buffer('Test This'))
      .then (results) =>
        @ws.find(results.fid)
        .then (locations) =>
          locations.should.exist
          next()

  describe 'Write', ->

    it 'should write a file', (next) ->
      @ws.write("#{__dirname}/test.txt")
      .then (results) =>
        results.count.should.equal 1
        next()

    it 'should write a non-existant file', (next) ->
      @ws.write("#{__dirname}/test33.txt")
      .catch (err) ->
        err.message.should.contain 'An error occured while upload files:'
        next()

    it 'should batch remove files in serial', (next) ->
      fids = []
      current = Promise.cast()
      _.forEach [0..10], (index) =>
        current = current.then =>
          @ws.write("#{__dirname}/test.txt")
          .then (results) ->
            fids.push results.fid
      current
      .then =>
        _.forEach fids, (fid) =>
          current = current.then =>
            @ws.remove(fid)
            .then (data) =>
              data.size.should.equal 35
        current
      .then ->
        next()

    it 'should batch remove files in parallel', (next) ->
      Promise.all((@ws.write("#{__dirname}/test.txt") for i in [0..10]))
      .then (results) =>
        Promise.all((@ws.remove(result.fid) for result in results))
      .then (results) =>
        for result in results
          result.size.should.equal 35
        next()

  describe 'Read', ->

    it 'should read a file', (next) ->
      @ws.write("#{__dirname}/test.txt")
      .then (results) =>
        @ws.read(results.fid)
      .then (data) ->
        data.toString().should.equal 'basic file\n'
        next()

    it 'should read a file and write into to a writable stream', (next) ->
      fs = require('fs')
      @ws.write("#{__dirname}/test.txt")
      .then (results) =>
        writeStream = fs.createWriteStream("./image.txt")
        @ws.read(results.fid, writeStream)
        writeStream.on 'close', ->
          (cat "./image.txt").should .equal 'basic file\n'
          rm "./image.txt"
          next()

    it 'should not be able to read an unknown file', (next) ->
      @ws.read('41,5005e865fa')
      .catch (err) ->
        err.message.should.equal 'File location for \'41,5005e865fa\' not found'
        next()

  describe 'Remove', ->

    it 'should remove a file', (next) ->
      @ws.write(new Buffer('Test This'))
      .then (results) =>
        @ws.remove(results.fid)
        .then (data) ->
          data.size.should.equal 9
          next()

    it 'should not be able to remove an unknown file', (next) ->
      @ws.remove('41,5005e865fa')
      .catch (err) ->
        err.message.should.equal 'File location for \'41,5005e865fa\' not found'
        next()
