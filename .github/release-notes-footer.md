
---

### What it needs

Nothing. No Full Disk Access, no accessibility, no entitlements — every fact
Corral shows is already readable by any process running as you.

### What it sends

Nothing, unless you turn on one thing. **Report Usage to Corral → Ask Kiro
for Account Usage** reads the sign-in token Kiro CLI keeps in its own store
and sends one HTTPS request every five minutes to the fixed AWS host the Kiro
IDE uses (`GetUsageLimits`), to show how many credits the account has left.
It is off by default, asks before it starts, keeps only the numbers that come
back, and follows no redirects. Everything else in Corral is file reads.
Something wrong? [Open an issue](https://github.com/popyapp/corral/issues).
