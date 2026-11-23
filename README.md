# BM Coding Agent

Ứng dụng desktop cho các coding agent, viết bằng Zig trên
[myzig](../../projects/myzig): giao diện native vẽ bằng GPU, không dùng
webview. Đây là bản port của [fx-ui](https://github.com/zaidmukaddam/fx-ui)
(Rust, GPUI), mở rộng từ agent `fx` sang mọi agent nói giao thức
[ACP](https://agentclientprotocol.com): Claude Code, Codex, Gemini CLI,
OpenCode, pi, fx, hoặc agent của riêng bạn.

![BM Coding Agent](docs/screenshot.png)

## Chạy thử

Cần Zig 0.17.0 và myzig được checkout tại `D:\projects\myzig` (đường dẫn
trong `build.zig.zon` là tương đối: `../../projects/myzig`).

```sh
zig build run                          # mở ứng dụng
zig build run -- <thư-mục>             # mở ứng dụng trên một thư mục
zig build run -- <thư-mục> -p "..."    # và gửi luôn prompt đầu tiên
zig build test                         # unit test và view test
```

Để có bản release kèm icon và bộ cài, dùng CLI của myzig (`myzig build`);
`myzig.zon` đặt tên cho ứng dụng.

## Cài trên máy khác

Cài từ `BM Coding Agent Setup <version> x86_64.exe` (hoặc giải nén bản
portable). Bộ cài chưa được ký số nên Windows SmartScreen sẽ hỏi trước
(More info → Run anyway). Những gì agent cần thì người dùng tự chuẩn bị:

- Node.js (nodejs.org) cho các agent khởi chạy bằng `npx` (Claude Code,
  Codex, pi); lần chạy đầu sẽ tải adapter về, các lần sau chạy từ cache của
  npm và kiểm tra phiên bản mới ở chế độ nền
- CLI của từng agent đã đăng nhập một lần (xem bảng bên dưới)
- git, cho bảng thay đổi và "Restore this turn's files"

## Agent

Settings → Agents liệt kê các agent và lệnh khởi chạy từng agent. Mặc định:

| Agent | Lệnh | Đăng nhập một lần bằng |
|---|---|---|
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` | `claude` |
| Codex | `npx -y @agentclientprotocol/codex-acp` | `codex login` |
| Gemini CLI | `gemini --experimental-acp` | `gemini` |
| fx | `fx acp` | `fx` |
| pi | `npx -y pi-acp` (chạy `pi --mode rpc`) | `pi` (các provider của nó, `pi auth`) |
| OpenCode | `opencode acp` | `opencode auth` |

`tools/mock-acp.mjs` là một agent giả để thử ứng dụng mà không cần tài
khoản: thêm nó với lệnh `node tools/mock-acp.mjs`. Nó stream một đoạn suy
nghĩ, một kế hoạch, các tool call (một cái xin phê duyệt), một chỉnh sửa vào
`MOCK_NOTES.md` và một câu trả lời Markdown; prompt có chữ "question" khiến
nó hỏi lại một câu, "subagent" thêm một subagent kiểu Claude Code, "spawn"
chạy một subagent dưới dạng session riêng.

`BM_AGENT_STATE=<file>` chạy ứng dụng với một file state khác (để test, thử
nghiệm). File mặc định nằm trong thư mục dữ liệu của ứng dụng
(`%APPDATA%\bm-agent\state.json` trên Windows).

## Tính năng (như trong fx-ui)

- Thư mục và session trong sidebar (kéo mép để nới rộng, double click để
  trả về mặc định), thanh tab khi sidebar đóng, trang Home với những gì đang
  chờ bạn, những gì đang chạy, session gần đây và đã lưu trữ
- Tab History ở Home: các session của thư mục theo danh sách agent trả về
  (`session/list`), kể cả session từ CLI của chính agent đó (danh sách
  `/resume` của `claude`); mở một session sẽ đưa nó vào sidebar và tải lên;
  hỗ trợ mọi agent (khởi chạy agent được chọn để hỏi); nút ✕ xóa session
  khỏi lịch sử của agent (`session/delete`)
- Agent của session mới được khởi chạy ngay, nhưng agent chỉ tạo session ở
  prompt đầu tiên: session không ai viết gì sẽ không được giữ lại (OpenCode
  thì giữ tất cả); các tùy chọn hiển thị theo lần cuối agent đưa ra
- Mỗi session một tiến trình agent; tiến trình rảnh sẽ được tắt và phát
  lại khi mở lại (với các agent hỗ trợ tải session)
- Câu trả lời dạng Markdown, stream trực tiếp: code được tô màu (có nút
  Copy), link mở được (cả trong prompt), ảnh theo đường dẫn và ảnh agent gửi
- Lệnh đầy đủ của một bước dài hiển thị trong tooltip
- Work log gồm suy nghĩ và các bước (các call giống nhau được gộp lại), kế
  hoạch của agent, các file mà lượt đó đã thay đổi
- Subagent nằm dưới bước đã khởi tạo nó, log riêng được thu gọn: các call
  Task của Claude Code, và subagent chạy như session riêng
  (`subagent_update` của ACP, như adapter của Codex gửi)
- Phê duyệt (cho phép một lần, luôn luôn, từ chối) kèm diff xem trước các
  chỉnh sửa; trả lời câu hỏi bằng phím số
- Thời gian của prompt, cùng Retry, Edit (sửa tại chỗ, Enter để gửi) và Copy
  khi rê chuột lên; cả hai đều gửi một lượt mới (ACP v1 không thu hồi được)
- Composer: `@` để chọn file, `/` cho skill và lệnh riêng của agent, dán hoặc
  chọn ảnh, hàng đợi khi một lượt đang chạy (steering với fx)
- Menu chọn model cho mọi agent, chế độ phân quyền, mức độ suy nghĩ, lượng
  context đã dùng
- Nhánh git ở header (và ở composer khi đủ chỗ): menu liệt kê các nhánh
  local và chuyển nhánh (`git switch`; nếu git từ chối thì hiển thị lý do)
- Bảng thay đổi: git status, diff, stage, unstage, discard; "Restore this
  turn's files" từ các snapshot git chụp trước và sau mỗi lượt
- Command palette (Ctrl+K), chia đôi màn hình (một session bên cạnh), đổi
  tên, lưu trữ, xóa vĩnh viễn (menu của session, tab Archived hoặc History ở
  Home): các file của Claude Code bị xóa khỏi `~/.claude` (transcript,
  subagent, kết quả tool, lịch sử file), agent khác thì được yêu cầu xóa
  (`session/delete`)
- Settings → Storage: dung lượng Claude Code (`~/.claude`), Codex
  (`~/.codex`) và OpenCode lưu session, theo từng project; xóa session của
  một project cũ hơn 7, 30 hoặc 90 ngày (hoặc tất cả), hoặc của mọi project
  cùng lúc. File của Claude Code do ứng dụng xóa; Codex và OpenCode được yêu
  cầu (`session/list`, `session/delete`) tự xóa khỏi database của chúng
- Settings: agent, model mặc định, hành vi (chỉ dẫn, thông báo), giao diện
  (sáng, tối hoặc theo hệ thống; màu nhấn; cỡ chữ, cũng chỉnh được bằng
  Ctrl+= Ctrl+- Ctrl+0), MCP server truyền vào mọi session mới, skill, mức
  sử dụng, thông tin

## Cấu trúc mã nguồn

| Thư mục | Nội dung |
|---|---|
| `src/acp/` | ACP: tiến trình agent (`proc.zig`, dùng job object trên Windows để mọi thứ nó khởi chạy đều kết thúc cùng nó), JSON-RPC qua pipe (`rpc.zig`), ý nghĩa các message (`proto.zig`) |
| `src/model/` | Các lượt của session được gộp từ update (`transcript.zig`), đọc tool call (`tools.zig`) |
| `src/host/` | git, state đã lưu, skill và bộ chọn file, tác vụ nền |
| `src/app/` | `App` và các hành động: agent, session, lượt, bản nháp |
| `src/views/` | Những gì `App` vẽ: frame, sidebar, home, transcript, composer, changes, palette, dialog, settings |
| `src/design/` | Design token Geist (tối và sáng), control dùng chung, bộ icon ([Lucide](https://lucide.dev), ISC) |

Mỗi file đều dưới 600 dòng, như trong myzig.

## Chưa port

Các tính năng dòng lệnh riêng của fx không có tương đương trong ACP: đăng
nhập tài khoản, báo cáo mức sử dụng và giới hạn gói, kiểm tra doctor, và tự
cập nhật. Đóng gói cho macOS (DMG, notarization) được thay bằng `myzig build`.
