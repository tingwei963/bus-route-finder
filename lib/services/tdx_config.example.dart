// 範本檔案,會被 Git 追蹤。
//
// 使用方式:
// 1. 複製這個檔案,改名為 tdx_config.dart(跟這個範本同一個資料夾)
// 2. 到 https://tdx.transportdata.tw/ 會員中心 > 資料服務 > API金鑰 取得你自己的金鑰
// 3. 填入下方兩個常數
//
// tdx_config.dart 已經被加進 .gitignore,不會被提交到 Git,
// 所以可以放心填入真實的 Client Secret。
class TdxConfig {
  static const String clientId = 'YOUR_CLIENT_ID';
  static const String clientSecret = 'YOUR_CLIENT_SECRET';
}
