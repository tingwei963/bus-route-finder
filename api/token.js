// Vercel serverless function: POST /api/token
//
// 把 TDX 的 Client ID / Secret 藏在後端環境變數(Vercel 專案設定 > Environment Variables),
// Flutter App 只呼叫這個 function 拿 access token,金鑰永遠不會出現在前端程式碼裡。
export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');

  const clientId = process.env.TDX_CLIENT_ID;
  const clientSecret = process.env.TDX_CLIENT_SECRET;

  if (!clientId || !clientSecret) {
    res.status(500).json({ error: 'server_misconfigured', error_description: 'TDX_CLIENT_ID / TDX_CLIENT_SECRET 未設定' });
    return;
  }

  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: clientId,
    client_secret: clientSecret,
  });

  const tdxRes = await fetch(
    'https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token',
    {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body,
    },
  );

  const data = await tdxRes.json();
  res.status(tdxRes.status).json(data);
}
