# sys-core-assets (系统网络加速及通信引擎自动同步分发库)

本项目用于全自动同步、编译并发布主项目运行所需的底层网络穿透及转发二进制文件。

通过添加干扰垃圾字节（哈希扰乱）和文件重命名（伪装组件），绕过云托管平台的防代理运行扫描。

---

## 📦 编译产出组件说明 (Releases 资产)

每个发布的二进制文件，均对原始程序执行了 **哈希重置（往文件末尾写入 32 字节随机数据）**。其文件 MD5/SHA256 具有完全随机的唯一性，防止被静态 Hash 特征拦截。

| 隐蔽资产文件名 | 对应的原始程序 | 功能说明 | 运行平台/架构 | 混淆类型 |
| :--- | :--- | :--- | :--- | :--- |
| **`web-engine-x64`** | `cloudflared` | 数据中继通信引擎 | linux/amd64 | 官方原装版 |
| **`web-engine-arm64`** | `cloudflared` | 数据中继通信引擎 | linux/arm64 | 官方原装版 |
| **`web-engine-x64-v2`** | `cloudflared` | 数据中继通信引擎 | linux/amd64 | **哈希指纹混淆版** (防拦截) |
| **`web-engine-arm64-v2`**| `cloudflared` | 数据中继通信引擎 | linux/arm64 | **哈希指纹混淆版** (防拦截) |
| **`cache-engine-x64`** | `xray` | 内存级数据加速内核 | linux/amd64 | **哈希指纹混淆版** (伪装成通用缓存组件) |
| **`cache-engine-arm64`** | `xray` | 内存级数据加速内核 | linux/arm64 | **哈希指纹混淆版** (伪装成通用缓存组件) |
| **`router-engine-x64`** | `sing-box` | 规则级流量路由内核 | linux/amd64 | **哈希指纹混淆版** (伪装成流量控制组件) |
| **`router-engine-arm64`** | `sing-box` | 规则级流量路由内核 | linux/arm64 | **哈希指纹混淆版** (伪装成流量控制组件) |

---

## 🔗 主网关对接直连链接

在部署 `ko` 主网关时，将下面的链接填入 `WEB_URL` 和 `CACHE_URL` 环境变量中，用于节点动态下载：

```bash
# 1. 穿透通信引擎下载地址 (对应填入 WEB_URL)
# 推荐填 v2 指纹混淆版，防止平台阻断
https://github.com/你的用户名/ko-vip/releases/latest/download/web-engine-{arch}-v2

# 2. 高速缓存转发内核下载地址 (对应填入 CACHE_URL)
https://github.com/你的用户名/ko-vip/releases/latest/download/cache-engine-{arch}
```

*注意：链接中的 `{arch}` 参数为主项目用于自动适配 `x64` 与 `arm64` 服务器的架构占位符，请务必原样保留。*
