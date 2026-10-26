# Docker 部署指南

把 Love小家 Web 端部署到自己的服务器。架构：**nginx 容器托管静态站点 + Supabase 提供后端**。

```
浏览器 ──> nginx 容器 (静态文件) ──> Supabase (Auth / Postgres / Storage / Realtime / Edge Functions)
```

容器内只包含构建出的静态文件，不含任何私密数据；所有业务数据都在 Supabase 侧。

## 前置条件

- 服务器已安装 Docker（20.10+）和 Docker Compose v2。
- 一个可用的 Supabase 项目（云免费版或自托管均可）：
  - 已执行 `supabase/migrations/` 迁移；
  - 已部署 `account-auth`、`heart-ai`、`zego-token` Edge Functions（需要 AI / 通话时）。

## 快速开始

```bash
# 1. 准备配置
cp .env.example .env
# 编辑 .env，至少填写：
#   NUXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
#   NUXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key

# 2. 构建并启动
docker compose up -d --build

# 3. 打开站点
# http://服务器IP:8080
```

端口在 `docker-compose.yml` 的 `ports` 中修改，例如改为 `"443:80"` 前请先阅读下面的 HTTPS 部分。

## 环境变量说明

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `NUXT_PUBLIC_SUPABASE_URL` | 是 | Supabase 项目地址 |
| `NUXT_PUBLIC_SUPABASE_ANON_KEY` | 是 | Supabase anon key（公开密钥，安全依赖 RLS 策略） |
| `NUXT_PUBLIC_AMAP_KEY` / `NUXT_PUBLIC_AMAP_SECURITY_CODE` | 否 | 高德地图，启用位置消息与实时地图 |
| `NUXT_PUBLIC_ZEGO_APP_ID` / `NUXT_PUBLIC_ZEGO_SERVER` | 否 | ZEGO 即构，启用语音/视频通话 |
| `NUXT_PUBLIC_TURN_URLS` / `NUXT_PUBLIC_TURN_USERNAME` / `NUXT_PUBLIC_TURN_CREDENTIAL` | 否 | WebRTC TURN 中继，弱网通话质量 |
| `NUXT_PUBLIC_APP_VERSION` / `NUXT_PUBLIC_UPDATE_MANIFEST_URL` | 否 | 版本号与更新清单地址 |

**重要：这些变量全部在构建期注入**。`npm run generate` 产出的是纯静态文件，运行时不再读取环境变量，所以：

- 每次修改 `.env` 后必须重新执行 `docker compose up -d --build`；
- 不要把任何服务端密钥（service_role key、`MIMO_API_KEY`、`ZEGO_SERVER_SECRET`）写进 `.env` 或构建参数——它们只应存在于 Supabase Edge Function Secrets 中。anon key 本身就是设计为公开的，放进前端镜像是安全的。

## HTTPS

生产环境建议在容器前加一层 HTTPS 反向代理，例如 Caddy：

```
love.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Supabase Auth 的回调地址需要在 Supabase 控制台按最终访问域名（`https://love.example.com`）配置，否则邮件确认/重置密码链接会跳错地方。

## 常用命令

```bash
docker compose logs -f web      # 查看日志
docker compose restart web      # 重启
docker compose down             # 停止并移除
docker compose up -d --build    # 拉取新代码后重新构建部署
```

## 自托管 Supabase（可选）

默认方案使用 Supabase 云服务。若要完全私有化，可参考 [supabase 官方仓库](https://github.com/supabase/supabase/tree/master/docker) 的 `docker compose` 方案自托管整套 Supabase（Postgres、GoTrue、PostgREST、Realtime、Storage、Studio 等），然后把 `NUXT_PUBLIC_SUPABASE_URL` 指向自己的实例，并用 Supabase CLI 部署 `supabase/functions/` 下的 Edge Functions。

自托管对服务器资源有一定要求（建议 4GB 内存以上），并需要自行做好备份与 TLS。
