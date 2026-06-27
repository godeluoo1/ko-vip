# sys-core-assets (系统加速及穿透引擎自动编译分发库)

本项目用于全自动同步、构建、编译并发布主项目运行所需的底层网络穿透及加速二进制文件。

通过添加干扰垃圾字节（哈希扰乱）和文件重命名（伪装组件），绕过云托管平台的防代理运行扫描。

---

## 📦 编译产出组件说明 (Releases 资产)

每个版本中发布的二进制文件，均对原始程序执行了 **哈希重置（往文件末尾写入 32 字节随机数据）**。其文件 MD5/SHA256 与官方原版完全不同，能有效突破封锁。

| 隐蔽资产文件名 | 对应的原始模块 | 运行平台/架构 | 混淆类型 |
| :--- | :--- | :--- | :--- |
| **`web-engine-x64`** | CF 穿透客户端 | linux/amd64 | 官方指纹原装版 |
| **`web-engine-arm64`** | CF 穿透客户端 | linux/arm64 | 官方指纹原装版 |
| **`web-engine-x64-v2`** | CF 穿透客户端 | linux/amd64 | **哈希签名混淆版** (防静态指纹拦截) |
| **`web-engine-arm64-v2`**| CF 穿透客户端 | linux/arm64 | **哈希签名混淆版** (防静态指纹拦截) |
| **`cache-engine-x64`** | X-core 转发核心 | linux/amd64 | **哈希签名混淆版** (伪装为缓存加速模块) |
| **`cache-engine-arm64`** | X-core 转发核心 | linux/arm64 | **哈希签名混淆版** (伪装为缓存加速模块) |
| **`router-engine-x64`** | S-box 路由核心 | linux/amd64 | **哈希签名混淆版** (伪装为路由控制模块) |
| **`router-engine-arm64`** | S-box 路由核心 | linux/arm64 | **哈希签名混淆版** (伪装为路由控制模块) |

---

## 🔗 主项目对接拉取直连链接

在部署 `ko` 主项目时，将下面的链接填入 `WEB_URL` 和 `CACHE_URL` 环境变量中，用于节点动态下载：

```bash
# 1. 穿透通信引擎下载地址 (对应填入 WEB_URL)
# 推荐填 v2 签名混淆版，防止平台阻断
https://github.com/你的用户名/ko-vip/releases/latest/download/web-engine-{arch}-v2

# 2. 高速缓存转发内核下载地址 (对应填入 CACHE_URL)
https://github.com/你的用户名/ko-vip/releases/latest/download/cache-engine-{arch}
```

*注意：链接中的 `{arch}` 参数为主项目用于自动适配 `x64` 与 `arm64` 服务器的架构占位符，请务必原样保留。*
