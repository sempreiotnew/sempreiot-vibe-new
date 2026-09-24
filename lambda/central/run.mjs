import "dotenv/config";
import http from "node:http";
import { handler } from "./index.mjs";

const PORT = process.env.PORT || 3001;

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST") {
    res.writeHead(405);
    res.end("Only POST");
    return;
  }

  let body = "";

  try {
    for await (const chunk of req) {
      body += chunk;
    }

    console.log("Incoming body:", body);

    const result = await handler({
      body,
      headers: req.headers,
      httpMethod: "POST",
    });

    res.writeHead(result.statusCode, { "Content-Type": "application/json" });
    res.end(result.body);
  } catch (err) {
    console.error("ERROR:", err);
    res.writeHead(500, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: err.message }));
  }
});

server.listen(PORT, () => {
  console.log(`Central lambda running → http://localhost:${PORT}`);
});
