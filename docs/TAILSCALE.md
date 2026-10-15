# Tailscale 内网：各客户端写法与塔台的实现

更新：2026-09-28。本文依据各客户端官方文档和开发者说明，用自建 Headscale 在手机和本机内核上实测，并用官方 Tailscale 账户在手机上验证了 Surge 与 Stash；版本号以文中注明的为准，发布前应重新核对。

## 它解决什么问题

代理客户端（Surge、Stash 等）开着时，手机上不能同时再开 Tailscale App：iOS 同一时间只允许一个 VPN。这几个客户端把 Tailscale 做成了一种**出站策略**：客户端自己加入 tailnet，成为其中一台设备，只把你用规则指定的流量（家里电脑的 Tailscale 地址、MagicDNS 名字、家里子网）送进 tailnet，其他流量照常走代理或直连。

要点：

- 它**不是代理节点**。目的地不在 tailnet 里时直接失败，不会回退直连，所以不能放进「节点选择」「自动选择」之类的策略组，只能靠规则把特定流量送过去。
- 每个客户端都会在 tailnet 里注册成**一台独立设备**（Surge 一台、Stash 一台……）。它们只负责访问别人，不会把手机发布成子网路由或出口节点，也不接受 tailnet 里的入站连接。
- 能访问什么，最终由 Tailscale 控制台决定：ACL、子网路由是否已批准、MagicDNS 是否开启。

## 在塔台里怎么用

1. 设置 → 节点与配置 → Tailscale 内网 → 添加。**不需要**再添加任何「Tailscale 节点」。
2. 字段：
   - **名称**：导出后在客户端里显示的策略名。
   - **控制服务器**：留空为官方 Tailscale；自建 Headscale 填它的 HTTPS 地址。
   - **Auth Key**：Stash、Clash / mihomo 和 sing-box MT 需要它；Surge 不写入，在自己的策略编辑页里登录。只存本机钥匙串，不同步 iCloud，但会写进导出的配置。输入框默认打码，可点眼睛图标查看，直接修改或清空后保存即替换或删除。
     - 生成时打开 **Reusable**（多个客户端各注册一台设备，一次性 Key 只能用一次）。
     - 设备加入后，到 Tailscale 控制台的 **Machines** 页面为它关闭 **Key Expiry**，否则到期后设备会掉线。
     - tailnet 开了设备审批时，生成 Key 勾选 **Pre-approved**。
   - **家里子网**（可选）：例如 `192.168.1.0/24`。家里必须有一台设备在 Tailscale 里发布这个子网，并在控制台批准。
   - **MagicDNS 后缀**：Tailscale 控制台 DNS 页面上的 `tailXXXX.ts.net`。**用 Stash 时必填**（见下文）；mihomo 和 sing-box 需要它才能按设备名访问；Surge 5.21+ 可以自己发现。
   - **设备名**：默认 `tower`，每个客户端再加后缀，例如 `tower-surge`、`tower-stash`。
3. 导出时选「完整配置」。「仅节点」模式不写 Tailscale。导出后可在「配置预览」里确认（Auth Key 在预览中打码）。

## 各客户端

### Surge（塔台写法需要 iOS 5.21+ / Mac 6.8+）

官方文档：<https://manual.nssurge.com/policies/tailscale.html>

写法由两部分组成：`[Proxy]` 里的一行策略，加一个同名的 `[Tailscale <section-name>]` 段。

```ini
[Proxy]
家里 = tailscale, section-name=tower-tailnet-1a2b3c4d

[Tailscale tower-tailnet-1a2b3c4d]
interactive-login = true      # 或 auth-key = tskey-auth-…，两者只能有一个
control-url = https://…       # 可选，默认官方
hostname = tower-surge        # 可选
```

- **登录**：`auth-key` 与 `interactive-login` 二选一。塔台**总是写 `interactive-login = true`，不写 Auth Key**：在 Surge 里编辑这个策略，从策略编辑页发起登录，在浏览器里授权。需要 **iOS 5.21 / Mac 6.8** 以上。这一行只是「引用本机登录状态」，不含凭据；换设备或本机状态丢失时要重新登录。
- 不写 Key 的原因：Surge 用 Auth Key 登录时按 Key 的哈希保存身份，配置里一旦出现 Key，就会注册成另一台设备，已经交互登录的那台被闲置。
- **身份保持**：交互登录的状态按**配置段名**保存；Auth Key 登录的状态按 **Key 的哈希**保存。改段名或换 Key 都会变成新设备。
- **自动路由**（5.21+ 默认开启，`auto-add-magic-dns-rule`）：会话建立后自动把 MagicDNS 后缀和每个对端的 Tailscale 地址路由到这个策略。**子网路由和出口节点不会自动路由**，需要显式规则。
- 其他字段：`exit-node`（`none` / `auto` / 指定设备）、`derp-only`、`idle-keepalive`（5.21+，默认常驻）、`prefer-ipv6`、`dns-server`、`mtu`；策略行上可加 `underlying-proxy`（让 DERP 走另一个策略，此时只走中继）、`test-url`（只接受 http://）、`test-timeout`。
- 注意：控制服务器地址按普通规则出站，**不能让它匹配到这个 Tailscale 策略本身**，否则会死锁。
- 没有出口节点时，Surge 的测速用 Tailscale 自己的连通探测；配置了公网 `test-url` 反而会失败。

### Stash（iOS / tvOS 3.4+，macOS 4.2+）

官方文档：<https://stash.wiki/en/proxy-protocols/proxy-types#tailscale>

```yaml
proxies:
  - name: 家里
    type: tailscale
    auth-key: tskey-auth-…         # 可选
    hostname: tower-stash          # 可选
    control-url: https://…         # 可选
    # exit-node: …                 # 可选
    # auto-route-disabled: false   # 可选
```

- **登录：目前必须用 `auth-key`。** 文档和 3.4.0 更新说明提到网页登录，但开发者说明 OAuth 接入仍在开发中，实测也无法在客户端里登录。塔台会把 Auth Key 写进 Stash 配置，没填时在导出页提示。
- **默认跳过 Tailscale 地址段**（开发者 2026-04-17 说明）：`100.64.0.0/10` 在 Stash 默认的「跳过代理」和「跳过路由」列表里，按 IP 访问 tailnet 设备的请求根本不进 Stash。**请用 MagicDNS 名字访问**（`设备名.tailXXXX.ts.net`）：域名会先解析成 Stash 的虚拟地址，能进入规则。实测：同一台 Mac，按名字能打开，按 IP 打不开。
- **家里子网同理**：私有网段通常也在默认跳过列表里。要按 IP 访问 tailnet 设备或家里子网，需要先在 Stash 的跳过代理和跳过路由中移除对应网段。这两个列表没有公开的配置字段，塔台无法替你修改。
- **换控制服务器**会使用另一份身份，需要重新认证。
- **自动路由**需要 **iOS 3.6+ / macOS 4.3+**：自动把 MagicDNS 后缀和对端地址交给这个节点，且排在配置规则之前。**3.4 / 3.5 没有自动路由**，必须写规则。
- `exit-node` 不写时会自动从可用出口节点里选一个；在 Tailscale 页面里手动选择的会覆盖配置。

### Clash / mihomo 系（mihomo 内核 1.19.25+）

官方文档：<https://wiki.metacubex.one/en/config/proxies/tailscale/>

适用：Clash Mi、Clash Verge Rev、FlClash、Mihomo Party、ClashMac 等，前提是内置 mihomo ≥ 1.19.25 且带 `with_gvisor` 构建标签（官方发布版带）。

```yaml
proxies:
  - name: 家里
    type: tailscale
    auth-key: tskey-auth-…       # 可选；不填则登录链接只打印在日志里
    control-url: https://…       # 可选
    hostname: tower-clash-mi
    state-dir: tower-tailnet-1a2b3c4d   # 身份保存位置，默认 tailscale
    udp: true
    accept-routes: true          # 要访问家里子网必须打开
    # exit-node: 100.64.0.1 / auto:any
```

- **没有自动路由**：必须写规则。目的地不在 Tailscale 路由里时直接失败，不回退直连。
- **懒启动**：第一条匹配的连接才会启动 Tailscale，所以第一次访问超时是正常的，重试即可。
- **没有交互登录界面**：不填 Key 时登录链接只出现在日志里，需要填 Auth Key。

### sing-box（1.12+）

官方文档：<https://sing-box.sagernet.org/configuration/endpoint/tailscale/>、<https://sing-box.sagernet.org/configuration/dns/server/tailscale/>

Tailscale 在 sing-box 里是 **endpoint**，不是 outbound；MagicDNS 需要单独的 `tailscale` DNS 服务器。

```json
{
  "endpoints": [{
    "type": "tailscale", "tag": "家里",
    "state_directory": "tower-tailnet-1a2b3c4d",
    "auth_key": "tskey-auth-…", "control_url": "https://…",
    "hostname": "tower-sing-box", "accept_routes": true
  }],
  "dns": {
    "servers": [{ "type": "tailscale", "tag": "家里 DNS", "endpoint": "家里" }],
    "rules": [{ "action": "route", "domain_suffix": ["tailXXXX.ts.net"], "server": "家里 DNS" }]
  },
  "route": {
    "rules": [{ "action": "route", "domain_suffix": ["tailXXXX.ts.net"],
                "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "192.168.1.0/24"],
                "outbound": "家里" }]
  }
}
```

- **没有自动路由**，也没有交互登录界面（登录链接在日志里）。
- 不填 MagicDNS 后缀时，只能用 Tailscale IP 访问。

### 不支持的客户端

| 客户端 | 情况 |
| --- | --- |
| Shadowrocket | 2.2.92 更新说明提到 Tailscale，但没有公开配置字段。实测 Clash YAML 的 `type: tailscale` 和 Surge 写法都没有向控制服务器注册。 |
| Loon、Quantumult X、Egern | 官方文档里没有 Tailscale 类型。 |
| Hiddify、Karing | 基于 sing-box，但应用本身还没有导入 Tailscale endpoint（Karing 源码中仍是 todo）。 |
| V2Box、Anywhere | 只有节点订阅，不涉及。 |

塔台对这些客户端跳过 Tailscale，并在导出页「兼容性提示」里说明。

## 塔台导出的规则

每个启用的 Tailscale 内网，塔台都会在**所有规则之前**插入：

| 规则 | 作用 |
| --- | --- |
| `DOMAIN-SUFFIX,<MagicDNS 后缀>` | 按设备名访问（填了后缀才写） |
| `IP-CIDR,100.64.0.0/10` | Tailscale IPv4 地址段 |
| `IP-CIDR6,fd7a:115c:a1e0::/48` | Tailscale IPv6 地址段 |
| `IP-CIDR,<家里子网>` | 家里局域网（经子网路由器） |

策略本身不加入任何策略组。Surge 5.21+ / Stash 3.6+ 自带自动路由，这些规则与之重复但无害；Stash 3.4、mihomo、sing-box 必须靠它们。Stash 下 IP 类规则默认不会生效（见上文跳过列表），只有域名规则起作用。

## 为什么塔台不能自动获取 Auth Key

2026-09-28 评估过：能不能像 Surge 那样，在塔台里点一下登录就拿到 Auth Key，省掉去后台手动生成的步骤？结论是不做。

**Surge 的交互登录不产生 Auth Key。** `interactive-login = true` 的意思是：Surge 自己运行 Tailscale 客户端，生成自己的设备密钥，再用浏览器授权这台设备。登录的结果是存在 Surge 沙盒里的设备身份，按配置段名保存，拿不出来。塔台就算自己走一遍同样的登录，得到的也只是「塔台」这台设备的身份，没法交给 Stash、mihomo 或 sing-box 用。每个客户端要么在自己的界面里登录，要么用配置里的 Auth Key。

Tailscale 官方有两条能拿到 Key 的路，都不适合塔台：

1. **[OAuth apps](https://tailscale.com/docs/features/oauth-apps/device-provisioning)**（授权码流程，2026-06 仍是 alpha）：用户同意授权后，换回来的 access token 本身就是 Auth Key。限制有三条：
   - App 必须由某个 tailnet 的 Owner 或 Admin 注册，**只有同一个 tailnet 的用户能授权**。公开发布的塔台没法给所有用户提供一个「用 Tailscale 登录」按钮。
   - 唯一的 scope 是 `auth_keys:create:once`。拿到的 Key **只能用一次，1 小时后过期**，也没有 refresh token。可是 Stash、Clash、sing-box 各自要注册一台设备，Key 又会写进导出的配置，客户端丢了状态之后要靠它重新注册。
   - 不支持 Headscale。
2. **[OAuth clients](https://tailscale.com/docs/features/oauth-clients) 或 API access token**（client credentials）：用户先在后台创建一个带 `auth_keys` 权限的凭据，贴进塔台，塔台再调 API 生成 Key。问题有三个：
   - 步骤比直接生成一个 Key 还多。
   - 塔台要长期保存一个能无限生成 Key 的凭据，风险远高于单个 Auth Key。
   - OAuth client 生成的 Key 必须带 tag，设备会归 tag 所有，ACL 行为和用户自己的设备不同。

   这也违背塔台「不代用户生成 Key、不修改账户」的原则。

如果以后想降低手动填写的成本，可以考虑两件事：

- 在 Auth Key 输入框旁边加一个链接，直接打开官方后台的 Keys 页面。填了 Headscale 地址时不显示。
- 用户切回塔台时，如果剪贴板里是 `tskey-auth-` 开头的内容，就自动填进去，规则和添加面板读剪贴板一样。

这两项用户暂时不要，没有排期。

## 已知问题与待确认

1. **实测情况**：用官方 Tailscale 账户，塔台导出的 Surge 配置按 IP 和按名字都能访问家里 Mac；Stash 按名字能访问，按 IP 被默认跳过列表挡住。Clash Mi、sing-box MT 的塔台导出只在自建 Headscale 和本机内核上验证过。
2. **Surge 必须是 iOS 5.21 / Mac 6.8 以上。** 塔台只写交互登录，更早的版本不认识 `interactive-login`，注册会失败。
3. **`100.64.0.0/10` 规则范围很大。** 它会把所有该网段的目的地都送进 tailnet，包括不属于你 tailnet 的地址（这个网段也是运营商级 NAT 的共享地址段）。实际很少有公网服务用它，但确实比 Surge / Stash 自动路由的「只路由已知对端」宽。
4. **家里子网规则在家时也生效**：手机连着家里 Wi-Fi 时，访问 `192.168.1.x` 也会绕 tailnet 走一圈。Tailscale 会尽量直连，通常仍能用，但比直接访问局域网慢。
5. Stash 的说明（用 MagicDNS 名字访问）会一直出现在导出页「兼容性提示」里，这是提醒，不是错误。
6. 刚导入或刚登录时，Surge 可能要十几秒才连上 Tailscale 中继；这期间访问会失败，稍等再试。

## 验证方法

1. 导出后在「配置预览」里确认：Surge 有 `= tailscale, section-name=` 行和末尾的 `[Tailscale …]` 段；Clash / Stash 的 `proxies:` 第一项是 `type: tailscale`；`rules:` 前几条是上表的规则。
2. 在客户端完成登录（或填 Key），在 Tailscale 控制台确认出现 `tower-surge` 之类的新设备。
3. 切到蜂窝网络，分别打开：家里电脑的 Tailscale IP、它的 MagicDNS 名字、家里子网里的某个地址（需已发布并批准子网路由）。
4. 重新导入同一份配置后，控制台里不应多出新设备。
