import json
import ssl
import sys
import urllib.request

sa = "/var/run/secrets/kubernetes.io/serviceaccount"
req = urllib.request.Request(
    "https://kubernetes.default.svc/apis/postgresql.cnpg.io/v1/clusters",
    headers={"Authorization": "Bearer " + open(sa + "/token").read()},
)
ctx = ssl.create_default_context(cafile=sa + "/ca.crt")
items = json.load(urllib.request.urlopen(req, context=ctx))["items"]

servers = {}
items.sort(key=lambda c: (c["metadata"]["namespace"], c["metadata"]["name"]))
for i, c in enumerate(items, 1):
    ns, name = c["metadata"]["namespace"], c["metadata"]["name"]
    boot = next(iter(c["spec"].get("bootstrap", {}).values()), {})
    db = boot.get("database", "app")
    user = boot.get("owner", db)
    servers[str(i)] = {
        "Name": name,
        "Group": ns,
        "Host": f"{name}-rw.{ns}.svc",
        "Port": 5432,
        "MaintenanceDB": db,
        "Username": user,
        "SSLMode": "require",
        "Shared": True,
        "SharedUsername": user,
    }

with open(sys.argv[1], "w") as f:
    json.dump({"Servers": servers}, f)
print(f"wrote {len(servers)} servers")
