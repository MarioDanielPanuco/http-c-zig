#HTTP-C

An HTTP implementation in C with POSIX standards


### Multi\-threading design
- A worker thread pool manages parallelization. `-t N` creates **N worker
threads**; the main thread is the dispatcher (it accepts connections and hands
each to the pool). So the process runs **N workers + 1 dispatcher = N+1 OS
threads**. `-t` defaults to 3 workers (4 OS threads total). See
`docs/DECISIONS.md` D17 for the thread-count convention and the
`test_scripts/threads_custom.sh` gate.


## Usage 

``` bash
./httpserver [-t threads] <port>
```
`port` is a single TCP port number (32768–65535 in the test harness). For
example, launching the server to listen on port 8080 with 2 worker threads:
```bash 
./httpserver -t 2 8080
```


### Description 


