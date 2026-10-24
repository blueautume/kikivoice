# 公开账号编号

用户可见的账号号为 `kiki_000001` 至 `kiki_999999`，由账号服务持久保存。

- 首次升级按 `created_at, account_id` 的稳定顺序给现存账号分配号码；后续启动保留已分配号码。
- Apple 新注册在写事务中分配最小空号，并以数据库唯一索引防止并发重复。
- 账号注销删除原账号后释放号码，后续注册优先复用空号。号段用尽时返回 503，注册事务回滚。
- 用户资料和社交资料通过可选的 `displayID` 返回公开号码；搜人支持六位数字及完整号码。

`account_id`、`login_id`、`sdk_user_id` 保持原身份。会话、私信、关注、房间权限和审核操作都使用稳定身份；复用公开号码不会继承原账号的数据。客户端展示和复制号码时使用 `displayID`，向 API 传递目标身份时继续使用 `id` / `userID`。旧服务器缺少 `displayID` 时客户端兼容显示原 ID。

语聊服务缓存 `users.display_id`，账号授权和资料同步会更新缓存；注销同时清理缓存。管理员界面显示公开号码，并在审核详情保留稳定编号用于核对历史记录。

## 发布与核验

首次发布先更新语聊服务兼容新字段，再更新账号服务，最后同步已有语聊缓存：

```bash
python3 backend/deploy/deploy_public_numbers.py voice --check
python3 backend/deploy/deploy_public_numbers.py account --check
python3 backend/deploy/deploy_public_numbers.py sync --check
python3 backend/deploy/deploy_public_numbers.py voice
python3 backend/deploy/deploy_public_numbers.py account
python3 backend/deploy/deploy_public_numbers.py sync
```

此发布器用于本次已核验的 4 账号迁移；账号数变化会停止发布，必须先重新核验并更新预期。它仅发布 API 源码，保留现有网站、协议、凭据与媒体服务。发布前执行已配置的完整备份，并在停服后保留一致性 SQLite 快照；恢复时只自动回滚代码，新增号码列保持前向兼容，不用旧快照覆盖后续业务写入。

发布结果位于 `output/public-number-layout-2026-10-23/`。2026-10-23 首次上线分配了 4 个公开号码，并同步 4 个语聊缓存；验证了原身份未改变、号码唯一完整、外键有效以及公网健康。
