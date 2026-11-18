# Chạy Frontend Trà Hiên V2 trên máy phát triển

Repo này chỉ có Store và Admin (Next.js). **Backend chạy từ repo BE riêng**: PostgreSQL, migration,
API .NET đều dựng theo `infra/README.md` của repo BE. Chạy BE trước, kiểm tra
`http://localhost:8080/openapi/v1.json` trả JSON rồi mới chạy FE.

## Cách 1: chạy trực tiếp bằng pnpm (khuyên dùng khi code FE)

Từ gốc repo, Node 22.22.2:

```powershell
corepack pnpm install --frozen-lockfile
$env:API_INTERNAL_URL = "http://localhost:8080"   # Store rewrite /api/* sang BE
corepack pnpm --dir apps/store exec next dev --port 3000
# Terminal khác:
corepack pnpm --dir apps/admin exec next dev --port 3001
```

## Cách 2: Docker Compose

```powershell
if (-not (Test-Path -LiteralPath infra/.env)) { Copy-Item infra/.env.example infra/.env }
docker compose -f infra/compose.dev.yml up -d --build
docker compose -f infra/compose.dev.yml watch   # hot reload, terminal riêng
```

| Biến trong `infra/.env` | Mặc định | Vai trò |
|---|---|---|
| `API_INTERNAL_URL` | `http://host.docker.internal:8080` | Địa chỉ BE nhìn từ container Store. |
| `STORE_PORT` / `ADMIN_PORT` | `3000` / `3001` | Cổng host của hai app. |

Compose project tên `teapremium-fe`, không đụng container của repo BE. Nếu repo BE cũng đang
chạy Store/Admin của nó trên cùng cổng, dừng chúng hoặc đổi cổng trong `.env`.

## Admin và đăng nhập

Admin gọi `/api/v1/*` **cùng origin** (DEC-16), không có rewrite Next. Mở thẳng
`http://localhost:3001` chỉ thấy khung giao diện và lỗi "Không thể kết nối" vì `/api` rơi vào Next (404).
BE cũng từ chối đăng nhập qua HTTP (`https_required`, cookie Secure).

Để đăng nhập, chạy Caddy theo `infra/caddy/Caddyfile.admin-local`:
`https://admin.localhost:8443` → `/api/*` sang API loopback **5080**, còn lại sang Admin **3001**.
API phải lắng nghe ở 5080 (repo BE: chạy native `--urls http://127.0.0.1:5080`, hoặc Compose đặt
`API_PORT=5080`) và cấu hình `Iam__AdminHost`/trusted proxy theo README của repo BE. Tài khoản
chủ đầu tiên tạo bằng lệnh `bootstrap-owner` của BE.

```powershell
caddy run --config infra/caddy/Caddyfile.admin-local --adapter caddyfile
```

Operator tự xác minh và tin cậy root CA của Caddy (`artifacts/p0-12-local/caddy-data`) trước khi mở trình duyệt.

## E2E đăng nhập Admin (IAM) với BE thật

Một lệnh dựng môi trường thử riêng bằng Docker (mạng riêng, PostgreSQL 17 mới có phân quyền `tp_*`
theo repo BE, seed owner ngẫu nhiên, API **Production**, Caddy TLS cổng 9443), chạy
`tests/iam/onboarding.spec.ts` rồi dọn sạch container và bí mật. Không đụng DB dev hay Caddy dev.
Cần Admin đang chạy ở cổng 3001 của máy (dev server hoặc compose FE):

```powershell
powershell -File apps/admin/tests/iam/run-iam-e2e.ps1 -BackendRepo D:\duong\dan\repo-be
```

Tham số: `-Port` (mặc định 9443), `-AdminUpstream` (mặc định `host.docker.internal:3001`),
`-KeepEnvironment` để giữ môi trường khi cần điều tra (thư mục `artifacts/iam-e2e` chứa bí mật, xóa sau khi xong).
Seed `.NET` tham chiếu source BE qua `-p:BackendRoot=<repo-be>/backend`; script tự truyền.

## Đổi API

Khi BE thêm/sửa endpoint: chạy BE, rồi `corepack pnpm generate:api` để cập nhật
`packages/api-client/openapi.json` và `src/generated/schema.ts`; `corepack pnpm check:api` kiểm lệch.
