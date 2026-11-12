# TaskScheduleTable

デスクトップに置いて使うタスク・予定表です。

## 新規インストール

`download/TaskScheduleTable_v2.4_READY.zip`

ZIPを展開して `タスク_予定表.exe` を起動します。

## 旧バージョンから更新

`download/TaskScheduleTable_Update_to_v2.4.zip`

1. 更新ZIPを旧バージョンのフォルダ内へ展開
2. `Update_to_v2.4.cmd` を実行
3. 旧EXEを `Backup_PreUpdate` へバックアップ
4. 本体EXEとVOICEをv2.4へ更新
5. 更新後のアプリを自動起動

タスク、日時、完了状態、背景、色、VOICE音量などのユーザーデータは
`%LOCALAPPDATA%\TaskScheduleTable` に保存されているため更新では削除しません。

## v2.4

- 旧バージョンからの更新用パッケージを追加
- 更新用CMDはASCIIのみ + CRLF固定
- 更新前EXEを自動バックアップ
- VOICE 22ファイルも更新
- v2.3の一覧レイアウト・期限順・完了チェック等を維持
