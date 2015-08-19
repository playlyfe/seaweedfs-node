#SeaWeedFs Nodejs Client

A seaweedfs client that is stable and resilient. You most likely will never lose a write or a read.

## Install
`npm install seaweedfs --save`

The SeaweedFS class allows you to make calls like write, find, read, remove, clusterStatus
```coffee
SeaweedFS = require('seaweedfs')
ws = new SeaweedFS()
ws.connect()
.then ->
    clusterStatus()
.then (status) ->
    console.log status
    ws.write(new Buffer('This is some text'))
.then (file_info) ->
    ws.find('1,00032423af')
.then (locations) ->
    console.log locations
    ws.read('1,00032423af')
.then (raw_data) ->
    console.log raw_data
    ws.remove('1,00032423af')
.then (response) ->
    console.log response
.catch (err) ->
    console.log err
```

## Documentation
You can initiate a client by default it connects to 1 master
```coffee
SeaweedFS = require('seaweedfs')
ws = new SeaweedFS({  # These are the default options
  masters: [   # The list of masters the client could connect to it
    {
      host: 'localhost'
      port: 9333
    }
  ]
  scheme: 'http' # Whether http or https
  retry_count: 60 # This is the no of times a request is retried until it fails
  retry_timeout: 2000 #ms # This is used to retry any request that fails within the timeout All these methods return a bluebird Promise. All these methods return the request data only when full_response is false but return headers, status, body of the response when full_response is true.
  log_name: 'SeaweedFS'
  log_level: 'info'
});  
```

### Methods
All these methods return a bluebird Promise

**clusterStatus()**  
This function will query the master status for status information. The callback contains an object containing the information.
```js
client.systemStatus()
.then(function(status) {
    console.log(status);
});
```

**write(file)**  
Use this to store files
```js
client.write("./file.png")
.then(function(fileInfo) {
    console.log(fileinfo)
});
```

You can also write multiple files:
```js
client.write(["./fileA.jpg", "./fileB.jpg"])
.then(function(fileInfo) {
    // This callback will be called for both fileA and fileB.
    // The fid's will be the same, to access each variaton just
    // add _ARRAYINDEX to the end of the fid. In this case fileB
    // would be: fid + "_1"
    var fidA = fileInfo;
    var fidB = fileInfo + "_1";
    console.log(fileInfo);
});
```

**find(fid)**  
This function can be used to find the locations of a file in the cluster.
```js
client.find(fileId)
.then(function(locations) {
    console.log(locations);
});
```

**read(fid, stream=null)**  
The read function supports streaming. To use simply do:
```js
client.read(fileId, fs.createWriteStream("read.png"));
```
If you prefer not to use streams just use:
```js
client.read(fileId)
.then(function(data) {
    console.log(data);
});
```

**remove(fid)**  
This function will delete a file from the store. It will be deleted from all locations.
```js
client.remove(fileId)
.then(function(body) {
    console.log("removed file.")
});
```

### Error Handling
Any Call to the client can result in an error you can just catch the error and do what you need to do then

Here is a list of errors that it can throw,
```js
new Error("file '#{file_id}' not found")
new Error("Failed request to #{uri}")
new Error("Unable to perform file operations on '#{file_id}': #{JSON.stringify(errors)}")
new Error("File location for '#{file_id}' not found")
new Error("File '#{file_id}' is not a valid file_id")
new Error("An error occured while upload files: #{JSON.stringify(results)}")
new Error('Could not connect to any nodes')
```

# License
Playlyfe Weedfs Node Client v1.0.0  
http://dev.playlyfe.com/  
Copyright(c) 2013-2015, Playlyfe IT Solutions Pvt. Ltd, support@playlyfe.com

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

