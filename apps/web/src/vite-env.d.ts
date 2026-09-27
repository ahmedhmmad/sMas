/// <reference types="vite/client" />
interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  readonly VITE_API_URL?: string;
  readonly VITE_DEV_TENANT_CODE?: string;
  readonly VITE_DEV_SCHOOL_SLUG?: string;
}
