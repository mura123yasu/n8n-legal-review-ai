/**
 * n8n から呼び出される PDF テキスト抽出 WebApp
 *
 * デプロイ設定:
 *   - 実行者: 自分（Googleアカウント）
 *   - アクセス: 全員（URLを知っている人）
 *
 * 使用する高度なサービス:
 *   - Drive API v2（appsscript.json で有効化済み）
 */

/**
 * ヘルスチェック用 GET エンドポイント
 * n8n からの接続確認に使用
 */
function doGet(e) {
  return ContentService
    .createTextOutput(JSON.stringify({ status: 'ok', service: 'pdf-extractor' }))
    .setMimeType(ContentService.MimeType.JSON);
}

/**
 * PDF テキスト抽出 POST エンドポイント
 *
 * リクエスト Body:
 *   { "fileId": "<Google Drive のファイルID>" }
 *
 * レスポンス（成功）:
 *   { "success": true, "text": "...", "fileId": "...", "charCount": 1234 }
 *
 * レスポンス（失敗）:
 *   { "success": false, "error": "...", "fileId": "..." }
 */
function doPost(e) {
  var tmpDocId = null;
  var fileId = null;

  try {
    // リクエストボディを JSON としてパース
    var body = JSON.parse(e.postData.contents);
    fileId = body.fileId;

    if (!fileId) {
      throw new Error('fileId が指定されていません');
    }

    // Google Drive からファイルを取得
    var file = DriveApp.getFileById(fileId);

    // OCR 変換: PDF → Google ドキュメント
    // Drive API v2 の Files.insert を使ってOCRを有効にした状態でインポート
    var tmpTitle = 'ocr_tmp_' + fileId + '_' + new Date().getTime();
    var resource = {
      title: tmpTitle,
      mimeType: MimeType.GOOGLE_DOCS
    };
    var options = {
      ocr: true,
      ocrLanguage: 'ja'
    };
    var tmpDoc = Drive.Files.insert(resource, file.getBlob(), options);
    tmpDocId = tmpDoc.id;

    // 変換された Google ドキュメントからテキストを取得
    var doc = DocumentApp.openById(tmpDocId);
    var body_ = doc.getBody();
    var text = body_.getText();

    // 一時ドキュメントをゴミ箱に移動（削除）
    DriveApp.getFileById(tmpDocId).setTrashed(true);
    tmpDocId = null; // 削除済みフラグ

    return ContentService
      .createTextOutput(JSON.stringify({
        success: true,
        text: text,
        fileId: fileId,
        charCount: text.length
      }))
      .setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    // エラー時: 一時ドキュメントが残っている場合は削除
    if (tmpDocId) {
      try {
        DriveApp.getFileById(tmpDocId).setTrashed(true);
      } catch (cleanupErr) {
        // クリーンアップ失敗は無視（元のエラーを優先）
        console.error('一時ドキュメントの削除に失敗:', cleanupErr.message);
      }
    }

    console.error('PDF 抽出エラー:', err.message, 'fileId:', fileId);

    return ContentService
      .createTextOutput(JSON.stringify({
        success: false,
        error: err.message,
        fileId: fileId
      }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}
