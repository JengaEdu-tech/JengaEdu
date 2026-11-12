# Deploy SMS OTP Password Recovery

1. Run `password-recovery-otp.sql` in the Supabase SQL Editor.
2. Deploy the Edge Function named `password-recovery` using the folder:
   `Supabase/functions/password-recovery/`
3. In Supabase Edge Function secrets, set:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `AFRICASTALKING_USERNAME`
   - `AFRICASTALKING_API_KEY`
   - optional: `AFRICASTALKING_SENDER_ID`
4. Ensure each school registration includes its phone number (this project already saves it in Auth user metadata).

Security behavior: OTPs are hashed, expire after 10 minutes, and are limited to five incorrect attempts. The SMS provider must be configured before OTP delivery will work.
