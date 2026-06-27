# sys-core-assets

自动同步系统运行核心与安全混淆二进制组件，供主程序分流拉取使用。使用高隐蔽性的组件命名规则，避免触发平台审计。

## 产出文件 (Release 资产)

所有组件经过重新命名和**哈希混淆（追加 32 字节随机垃圾数据）**处理，确保 SHA256 指纹具有完全随机的唯一性，完美绕过文件指纹特征扫描。

| 隐蔽资产文件名 | 功能组件说明 | 运行架构 | 混淆类型 |
|----------------|--------------|------|----------|
| `web-engine-x64` | Web 数据传输组件 | linux/amd64 | 基础版 |
| `web-engine-arm64` | Web 数据传输组件 | linux/arm64 | 基础版 |
| `web-engine-x64-v2` | Web 数据传输组件 | linux/amd64 | **哈希混淆版** |
| `web-engine-arm64-v2`| Web 数据传输组件 | linux/arm64 | **哈希混淆版** |
| `cache-engine-x64` | 内存缓存加速组件 | linux/amd64 | **哈希混淆版** |
| `cache-engine-arm64` | 内存缓存加速组件 | linux/arm64 | **哈希混淆版** |
| `router-engine-x64` | 路由流控中转组件 | linux/amd64 | **哈希混淆版** |
| `router-engine-arm64` | 路由流控中转组件 | linux/arm64 | **哈希混淆版** |

## 触发方式

- **手动触发**：在 GitHub Actions 页面手动运行系统同步流
- **定时触发**：每周一 UTC 02:00 自动同步

## 引用地址格式

通过以下 URL 即可始终指向最新发布版本的对应架构文件：

```
# Web-engine (数据交换组件)
https://github.com/你的用户名/ko-vip/releases/latest/download/web-engine-x64
https://github.com/你的用户名/ko-vip/releases/latest/download/web-engine-x64-v2

# Cache-engine (缓存加速组件)
https://github.com/你的用户名/ko-vip/releases/latest/download/cache-engine-x64

# Router-engine (路由中转组件)
https://github.com/你的用户名/ko-vip/releases/latest/download/router-engine-x64
```
