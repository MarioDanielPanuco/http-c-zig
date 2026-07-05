-- wrk PUT script for bench/bench.sh.
-- Sends the file named by $WRK_BODY_FILE as the request body on every request.
-- Body is read once at init (wrk runs this per thread), not per request.
wrk.method = "PUT"

local path = os.getenv("WRK_BODY_FILE")
if path then
  local f = io.open(path, "rb")
  if f then
    wrk.body = f:read("*a")
    f:close()
  end
end

wrk.headers["Content-Type"] = "application/octet-stream"
