# ko-vip

自动同步官方原装 [cloudflared](https://github.com/cloudflare/cloudflared) 二进制文件，供主项目下载使用。

## 用途

通过 GitHub Actions 自动拉取上游最新 Release 官方编译原包，重命名为固定文件名并发布到 Release，方便主项目通过稳定、高可用的 URL 进行下载，避免某些容器网络环境直连官方下载失败。

## 产出文件

| 文件名 | 对应官方程序 | 架构 |
|--------|----------|------|
| `bot-linux-amd64` | cloudflared | linux/amd64 |
| `bot-linux-arm64` | cloudflared | linux/arm64 |

## 触发方式

- **手动触发**：在 GitHub Actions 页面手动运行 `workflow_dispatch`
- **定时触发**：每周一 UTC 02:00 自动同步（`cron: '0 2 * * 1'`）

## 镜像引用地址

Release 下载地址格式：

```
https://github.com/godeluoo1/ko-vip/releases/latest/download/bot-linux-amd64
https://github.com/godeluoo1/ko-vip/releases/latest/download/bot-linux-arm64
```

通过 `/releases/latest/download/` 路径始终指向最新同步的原装版本，免去手动更新 URL。
