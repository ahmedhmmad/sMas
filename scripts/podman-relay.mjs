// وسيط TCP للتطوير المحلي على Windows + Podman (rootful/WSL).
// المشكلة: Podman ينشر المنافذ بقواعد DNAT داخل الـVM لا بمنفذ يستمع، فوسيط WSL لا ينقلها إلى
// 127.0.0.1 على Windows. الحل: 127.0.0.1:<port> ← <VM IP>:<port>. لا يغيّر إعدادات Podman.
// الاستعمال: node scripts/podman-relay.mjs            (يبقى يعمل حتى Ctrl+C)
import net from "node:net";
import { execSync } from "node:child_process";

const PORTS = (process.env.RELAY_PORTS ?? "54321,54322").split(",").map(Number);
const MACHINE = process.env.PODMAN_MACHINE ?? "podman-machine-default";

const vmIp =
  process.env.PODMAN_VM_IP ??
  execSync(`wsl -d ${MACHINE} -e sh -c "ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1"`, {
    encoding: "utf8",
  }).trim();

if (!/^\d+\.\d+\.\d+\.\d+$/.test(vmIp)) {
  console.error(`✗ تعذّر تحديد عنوان الـVM (${JSON.stringify(vmIp)})`);
  process.exit(1);
}

for (const port of PORTS) {
  net
    .createServer((client) => {
      const upstream = net.connect(port, vmIp);
      client.pipe(upstream).pipe(client);
      const close = () => { client.destroy(); upstream.destroy(); };
      client.on("error", close);
      upstream.on("error", close);
    })
    .on("error", (e) => { console.error(`✗ ${port}: ${e.message}`); process.exit(1); })
    .listen(port, "127.0.0.1", () => console.log(`relay 127.0.0.1:${port} → ${vmIp}:${port}`));
}
