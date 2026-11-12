# fwd-lab

Four `bgp4rd` routers, each in its own AS, peering eBGP, and installing what they learn in the kernel's main table so packets really cross them. `a` (AS 65001) pings `d` (AS 65004) from loopback 10.255.0.1 to 10.255.0.4. `b` (AS 65002) has two ways to reach `d`: the direct link, and through `c` (AS 65003).

```
a ----- b ----- c ----- d
        |               |
        +---------------+
```

It exercises:
- every router learning every loopback, and `b` choosing the direct link on AS_PATH length
- the B to D link going down, and traffic moving through `c` once the hold timer ends the session
- the link coming back, and traffic moving back
- the B to D session stopped by hand, and the same move with no hold timer to wait out
- `d` cut off entirely, and its loopback withdrawn everywhere

The four scenarios in `scenarios/` drive these. `capture.sh` pings across the lab and checks which way the packets went. README.md has the addressing and the commands.
