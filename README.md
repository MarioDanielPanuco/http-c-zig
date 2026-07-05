#HTTP-C

An HTTP implementation in C with POSIX standards


### Multi\-threading design
- I'm using a worker thread pool to manage parallelization.
This means if I have N total threads, then there are $$n-1$$ workers in the thread pool and one dispatcher.


## Usage 

``` bash
./httpserver [-t threads] <port>
```
For example, launching the server to listen on port (8080:80) with 2 threads: 
```bash 
./httpserver -t 2 8080:80 
```


### Description 


