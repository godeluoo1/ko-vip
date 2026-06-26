# ko-vip

自动同步官方原装及哈希混淆版二进制文件，供主项目下载使用。使用高隐蔽性的文件命名规则，避免触发平台审计。

## 产出文件 (Release 资产)

所有文件均由官方 Release 编译原包拉取，经过重命名和**哈希混淆（追加 32 字节随机垃圾数据）**处理，确保 SHA256 指纹具有完全随机的唯一性。

| 隐蔽资产文件名 | 对应官方程序 | 架构 | 混淆类型 |
|----------------|--------------|------|----------|
| `web-helper-x64` | cloudflared | linux/amd64 | 原装版 |
| `web-helper-arm64` | cloudflared | linux/arm64 | 原装版 |
| `web-helper-x64-v2` | cloudflared | linux/amd64 | **哈希混淆版** |
| `web-helper-arm64-v2`| cloudflared | linux/arm64 | **哈希混淆版** |
| `app-cache-x64` | xray | linux/amd64 | **哈希混淆版** (伪装成缓存组件) |
| `app-cache-arm64` | xray | linux/arm64 | **哈希混淆版** (伪装成缓存组件) |
| `app-router-x64` | sing-box | linux/amd64 | **哈希混淆版** (伪装成静态路由包) |
| `app-router-arm64` | sing-box | linux/arm64 | **哈希混淆版** (伪装成静态路由包) |

## 触发方式

- **手动触发**：在 GitHub Actions 页面手动运行 `workflow_dispatch`
- **定时触发**：每周一 UTC 02:00 自动同步（`cron: '0 2 * * 1'`）

## 镜像引用地址格式

通过以下 URL 即可始终指向最新发布版本：

```
# Web-helper (Cloudflared)
https://github.com/godeluoo1/ko-vip/releases/latest/download/web-helper-x64
https://github.com/godeluoo1/ko-vip/releases/latest/download/web-helper-x64-v2

# App-cache (Xray)
https://github.com/godeluoo1/ko-vip/releases/latest/download/app-cache-x64

# App-router (Sing-box)
https://github.com/godeluoo1/ko-vip/releases/latest/download/app-router-x64
```

