// netlify/functions/sign-upload.js
//
// Receives a request from the browser asking for a presigned PUT URL
// to upload a recording to DigitalOcean Spaces. Validates the user's
// Supabase session before signing, so only signed-in @lifehousereentry.com
// people can upload.
//
// EXPECTED ENVIRONMENT VARIABLES (set in Netlify dashboard, not in code):
//   SPACES_KEY              = your DO Spaces Access Key ID
//   SPACES_SECRET           = your DO Spaces Secret (NEVER paste in chat)
//   SPACES_BUCKET           = "life-house-workshop-studio"
//   SPACES_REGION           = "sfo3"
//   SUPABASE_URL            = "https://znxwwbauqiqbthbofgyw.supabase.co"
//   SUPABASE_PUBLISHABLE    = "sb_publishable_..."
//   ALLOWED_DOMAIN          = "lifehousereentry.com"

import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createClient } from "@supabase/supabase-js";

export default async (req) => {
  // ---- CORS preflight ----------------------------------------------
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization"
      }
    });
  }

  if (req.method !== "POST") {
    return json(405, { error: "Method not allowed" });
  }

  try {
    // ---- 1. Authenticate the caller via their Supabase session -----
    const auth = req.headers.get("authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
    if (!token) return json(401, { error: "Missing auth token" });

    const supa = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_PUBLISHABLE
    );
    const { data: userData, error: userErr } = await supa.auth.getUser(token);
    if (userErr || !userData?.user) return json(401, { error: "Invalid session" });

    const email = (userData.user.email || "").toLowerCase();
    const allowedDomain = (process.env.ALLOWED_DOMAIN || "lifehousereentry.com").toLowerCase();
    if (!email.endsWith("@" + allowedDomain)) {
      return json(403, { error: "Not authorized for this domain" });
    }

    // ---- 2. Validate the request body ------------------------------
    const body = await req.json();
    const objectKey = body?.objectKey;
    const contentType = body?.contentType || "video/webm";

    if (!objectKey || typeof objectKey !== "string") {
      return json(400, { error: "Missing objectKey" });
    }
    // Only allow our recordings/ prefix to keep the bucket tidy
    if (!objectKey.startsWith("recordings/") && !objectKey.startsWith("uploads/")) {
      return json(400, { error: "Invalid objectKey path" });
    }
    // Block path traversal
    if (objectKey.includes("..") || objectKey.includes("//")) {
      return json(400, { error: "Invalid objectKey" });
    }

    // ---- 3. Generate the presigned PUT URL --------------------------
    const region = process.env.SPACES_REGION || "sfo3";
    const bucket = process.env.SPACES_BUCKET;
    const endpoint = `https://${region}.digitaloceanspaces.com`;

    const s3 = new S3Client({
      region: "us-east-1",  // DO Spaces uses us-east-1 as the SDK signing region
      endpoint,
      forcePathStyle: false,
      credentials: {
        accessKeyId: process.env.SPACES_KEY,
        secretAccessKey: process.env.SPACES_SECRET
      }
    });

    const cmd = new PutObjectCommand({
      Bucket: bucket,
      Key: objectKey,
      ContentType: contentType,
      ACL: "public-read"  // so the team can stream playback without further signing
    });

    const uploadUrl = await getSignedUrl(s3, cmd, { expiresIn: 60 * 15 }); // 15 min
    const publicUrl = `https://${bucket}.${region}.digitaloceanspaces.com/${objectKey}`;

    return json(200, { uploadUrl, publicUrl, expiresIn: 900 });

  } catch (e) {
    console.error("sign-upload error:", e);
    return json(500, { error: e.message || "Server error" });
  }
};

function json(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization"
    }
  });
}
