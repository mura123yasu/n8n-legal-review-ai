# ワークフロー設計詳細

## ワークフロー全体フロー

```
[Cloud Scheduler: */5 * * * *]
         │ POST /webhook/contract-review-poller
         ▼
[1] Contract Review Poller（Webhook Trigger）
         │
         ▼
[2] List Files in Inbox（Google Drive: fileSearch）
         │ 01_inbox フォルダの PDF を列挙
         ▼
[3] Files Found?（IF）
         │
    ┌────┴──────┐
 True（あり）  False（なし）
    │            │
    ▼            ▼
[5] Split     [4] No Files - End
  In Batches   （処理終了）
    │
    ▼ 1件ずつ処理
[6] Move to Processing（Google Drive: move）
    │ 01_inbox → 02_processing
    ▼
[7] GAS WebApp - Extract Text（HTTP Request）
    │ PDF → テキスト
    ▼
[8] Gemini API - Analyze Contract（HTTP Request）
    │ テキスト → JSON 分析結果
    ▼
[9] Parse Gemini Response（Code）
    │ JSON パース + メタデータ付加
    ▼
[10] Create Review Document（Google Docs: create）
    │ 04_results にドキュメント生成
    ▼
[11] Move to Reviewed（Google Drive: move）
    │ 02_processing → 03_reviewed
    ▼
[12] Gmail - Send Notification（Gmail: send）
    │ 完了メール送信
    ▼
[13] Sheets - Append Log（Google Sheets: appendOrUpdate）
    │ ログ記録
    ▼
 次のファイルへ（Split In Batches に戻る）

        エラー発生時:
[Error Trigger]
    │
    ▼
[Move Back to Inbox]（Google Drive: move）
    │ 02_processing → 01_inbox
    ▼
[Gmail - Error Notification]（Gmail: send）
    │ エラーメール送信
```

---

## 各ノード詳細

### [1] Contract Review Poller（Webhook Trigger）

| 設定 | 値 |
|---|---|
| HTTP Method | POST |
| Path | `contract-review-poller` |
| URL | `https://<cloud-run-url>/webhook/contract-review-poller` |
| Response Mode | lastNode（全処理完了後にレスポンス） |

Cloud Scheduler からの JSON ボディ:
```json
{ "source": "cloud-scheduler", "trigger": "contract-review-poll" }
```

### [2] List Files in Inbox

| 設定 | 値 |
|---|---|
| Operation | fileSearch |
| Query | `='{{ $vars.DRIVE_INBOX_FOLDER_ID }}' in parents and mimeType='application/pdf' and trashed=false` |
| Return All | true |

### [3] Files Found?

- True: ファイルが1件以上ある場合 → 処理継続
- False: ファイルがない場合 → No Files - End で終了

### [5] Split In Batches

- batchSize: 1（PDF を1件ずつ逐次処理）
- 全件処理後に自動終了

### [6] Move to Processing（二重処理防止）

01_inbox から 02_processing に移動することで、別の n8n インスタンスが同じファイルを処理することを防ぐ。

### [7] GAS WebApp - Extract Text

- タイムアウト: 120秒（大きな PDF の OCR は時間がかかる場合がある）
- レスポンス: `{ "success": true, "text": "...", "charCount": 1234 }`

### [8] Gemini API - Analyze Contract

- モデル: `gemini-1.5-pro`
- Temperature: 0.1（安定した出力のため低めに設定）
- Max Output Tokens: 8192
- プロンプト: `prompts/contract-review.md` を参照

### [9] Parse Gemini Response（Code ノード）

```javascript
// Gemini のレスポンスから本文を取得
const responseText = $input.item.json.candidates[0].content.parts[0].text;

// JSON パース（コードブロックで囲まれている場合にも対応）
let analysis;
try {
  analysis = JSON.parse(responseText);
} catch (e) {
  const jsonMatch = responseText.match(/```json\n?([\s\S]*?)\n?```/);
  if (jsonMatch) {
    analysis = JSON.parse(jsonMatch[1]);
  } else {
    throw new Error('JSON パース失敗');
  }
}

// メタデータを追加
analysis.reviewed_at_utc = new Date().toISOString();
analysis.fileName = $('Split In Batches').item.json.name;
analysis.fileId = $('Split In Batches').item.json.id;
analysis.riskSummary = `高:${analysis.risk_counts.high}件 中:${analysis.risk_counts.medium}件 低:${analysis.risk_counts.low}件`;

return [{ json: analysis }];
```

### [10] Create Review Document

ドキュメントタイトル: `[レビュー済]_<ファイル名>_YYYYMMDD`

ドキュメント内容:
```
【契約書AIレビュー結果】

ファイル名: <元のファイル名>
レビュー日時: <ISO 8601>

■ 総評
<200字以内の全体総評>

■ リスク件数
高:N件 中:N件 低:N件

■ 総合リスクレベル: 高|中|低

────────────────────────────
■ リスク詳細

[1] <カテゴリ名> (<リスクレベル>)
  該当箇所: <原文引用>
  リスク: <リスク説明>
  対応: <推奨アクション>
...

────────────────────────────
■ 不足している条項
・<条項名>

※ 本レビューはAIによる補助資料です。最終判断は必ず法務担当者が行ってください。
```

---

## エラーハンドリング設計

### エラーワークフロー設定

n8n の「Settings」→「Error Workflow」に本ワークフローの ID を設定することで、実行エラー時に Error Trigger が起動します。

### エラー時の動作

1. **ファイルの保護**: 02_processing に残っているファイルを 01_inbox に戻す
2. **担当者通知**: エラー発生ノード名とエラーメッセージをメールで送信
3. **次回以降の再試行**: 次の Cloud Scheduler 実行時（最大 5 分後）に再度処理

### 各ノードのエラーケース

| ノード | エラーケース | 対応 |
|---|---|---|
| GAS WebApp | PDF の OCR 失敗、タイムアウト | エラートリガー発火 |
| Gemini API | API 制限、レスポンス形式不正 | エラートリガー発火 |
| Parse Response | JSON パース失敗 | エラートリガー発火 |
| Google Docs | 権限エラー | エラートリガー発火 |

---

## Google Drive フォルダ構成と役割

```
📁 契約書レビュー/
  ├── 📁 01_inbox/
  │     役割: 処理待ち PDFs の受け取り口
  │     操作: ユーザーが手動でドロップ
  │
  ├── 📁 02_processing/
  │     役割: 処理中ファイルの一時置き場（二重処理防止）
  │     操作: n8n が自動で移動・管理
  │
  ├── 📁 03_reviewed/
  │     役割: 処理完了済み原本の保管
  │     操作: n8n が自動で移動
  │
  └── 📁 04_results/
        役割: AI レビュー結果ドキュメントの保管
        操作: n8n が Google Docs として自動生成
```

### 二重処理防止の仕組み

- ファイルは `01_inbox → 02_processing` に移動してから処理を開始
- n8n が min=0（複数インスタンスが同時起動する可能性がある）でも、
  `02_processing` に移動済みのファイルは `01_inbox` の検索結果に出てこないため安全

---

## Google Sheets ログ仕様

シート名: `ログ`

| カラム名 | 型 | 内容 |
|---|---|---|
| 処理日時 | datetime (ISO 8601) | レビュー完了時刻（UTC） |
| ファイル名 | string | 処理した PDF のファイル名 |
| 高リスク数 | number | 高リスク項目の件数 |
| 中リスク数 | number | 中リスク項目の件数 |
| 低リスク数 | number | 低リスク項目の件数 |
| 総合リスク | string | 高 / 中 / 低 |
| ステータス | string | 「完了」または「エラー」 |
| DocsURL | url | 生成されたレビュードキュメントの URL |

---

## n8n Variables 一覧

n8n UI の「Settings」→「Variables」で設定：

| 変数名 | 例 | 説明 |
|---|---|---|
| `DRIVE_INBOX_FOLDER_ID` | `1ABC...` | 01_inbox の Google Drive フォルダ ID |
| `DRIVE_PROCESSING_FOLDER_ID` | `1DEF...` | 02_processing のフォルダ ID |
| `DRIVE_REVIEWED_FOLDER_ID` | `1GHI...` | 03_reviewed のフォルダ ID |
| `DRIVE_RESULTS_FOLDER_ID` | `1JKL...` | 04_results のフォルダ ID |
| `SHEETS_LOG_ID` | `1MNO...` | ログ用スプレッドシートの ID |

フォルダ ID の取得方法: Google Drive でフォルダを開いた際の URL
`https://drive.google.com/drive/folders/<ここがフォルダID>`

---

## Gemini プロンプト設計の考え方

詳細は `prompts/contract-review.md` を参照。

### 出力を JSON に強制する理由

- n8n の Code ノードで構造化データとしてパースできる
- リスク件数の集計・表示が容易
- 将来の拡張（DB 保存、ダッシュボード化）に対応しやすい

### Temperature を 0.1 に設定する理由

- 契約書分析は一貫性・再現性が重要
- 創造性より正確性を優先
- JSON フォーマットの遵守率が高まる
