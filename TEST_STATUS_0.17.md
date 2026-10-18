# sa_plugin_http_server 0.17 测试状态

验证时间: 2026-10-18 (clean rebuild), zig 0.17.0, sci main, LLVM-20
命令: `zig build test --summary all --test-timeout 60s`

## 结果: 17 通过 / 1 跳过 (共18) — 全绿

跳过: SIGPIPE handler (平台相关)

## 已修 (本轮, 均已推送到 origin/0.17)
- src/plugin.zig: Abi flush (对标 http_client; 缺 flush 导致
  missing-operand 等 CLI 诊断丢失)
- tests: scaffold/serve/stream 在 expect 前显式 flush
  (ForwardWriter 缓冲; defer flush 在 expect 之后)
- build.zig: 新增 -Dtest-filter 便于单测隔离
- vite_api parseHead: 无 body 可复用请求必须推进 request_start
  (否则第二个 accept 重解析第一个请求 → keep-alive 失败)
- tests streamRead: EAGAIN → WouldBlock (flush 测试期望)
- vite_api acceptFresh: raw accept4 替代 std accept
  (0.17 Threaded 后端把非阻塞 listener 上的 EAGAIN 当 errnoBug panic;
  poll→accept TOCTOU 触发 serve_threaded 崩溃)

## 2026-10-18 复验 (S2)
- 干净复测 (.zig-cache 清理后): 17 通过 / 1 跳过 (共18) — 全绿
- vite_api.zig 0.17 重写已完成，无残留编译错误
