-- تسعيرتي DZ — إصلاح طلبات PRO + قفل الميزات + الأرشفة
-- شغّل هذا الملف كاملاً في Supabase > SQL Editor (آمن لإعادة التشغيل)

-- 1) أعمدة subscription_requests الناقصة
ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS merchant_name  text,
  ADD COLUMN IF NOT EXISTS phone          text,
  ADD COLUMN IF NOT EXISTS receipt_url    text,
  ADD COLUMN IF NOT EXISTS payment_method text DEFAULT 'baridimob',
  ADD COLUMN IF NOT EXISTS amount         numeric DEFAULT 1000,
  ADD COLUMN IF NOT EXISTS plan           text DEFAULT 'pro_monthly',
  ADD COLUMN IF NOT EXISTS status         text DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS admin_note     text,
  ADD COLUMN IF NOT EXISTS reviewed_at    timestamptz,
  ADD COLUMN IF NOT EXISTS created_at     timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS subscription_requests_merchant_status_idx
  ON public.subscription_requests (merchant_id, status);

-- 2) أعمدة الاشتراك والأرشفة
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_pro         boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS pro_expires_at timestamptz;

ALTER TABLE public.quote_requests
  ADD COLUMN IF NOT EXISTS archived_by_customer boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS archived_by_merchant boolean DEFAULT false;

-- 3) دالة التحقق من اشتراك PRO نشط (حالة + تاريخ انتهاء)
CREATE OR REPLACE FUNCTION public.is_active_pro(uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = uid
      AND p.is_pro = true
      AND (p.pro_expires_at IS NULL OR p.pro_expires_at > now())
  );
$$;

-- 4) منع التاجر من تفعيل PRO لنفسه عبر تعديل ملفه الشخصي
CREATE OR REPLACE FUNCTION public.protect_pro_columns()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.role() = 'authenticated'
     AND (NEW.is_pro IS DISTINCT FROM OLD.is_pro
          OR NEW.pro_expires_at IS DISTINCT FROM OLD.pro_expires_at)
     AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    NEW.is_pro := OLD.is_pro;
    NEW.pro_expires_at := OLD.pro_expires_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_pro_columns ON public.profiles;
CREATE TRIGGER trg_protect_pro_columns
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_pro_columns();

-- 5) RLS: الملف الشخصي (إصلاح الحفظ)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- 6) RLS: طلبات الاشتراك
ALTER TABLE public.subscription_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "subreq_insert_own" ON public.subscription_requests;
CREATE POLICY "subreq_insert_own" ON public.subscription_requests
  FOR INSERT TO authenticated
  WITH CHECK (merchant_id = auth.uid() AND status = 'pending');
DROP POLICY IF EXISTS "subreq_select_own_or_admin" ON public.subscription_requests;
CREATE POLICY "subreq_select_own_or_admin" ON public.subscription_requests
  FOR SELECT TO authenticated
  USING (merchant_id = auth.uid()
         OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));
DROP POLICY IF EXISTS "subreq_admin_update" ON public.subscription_requests;
CREATE POLICY "subreq_admin_update" ON public.subscription_requests
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- 7) RLS: اللوجيسيال (المخزون) للمشتركين النشطين فقط في الكتابة
ALTER TABLE public.merchant_inventory ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "inventory_select_all" ON public.merchant_inventory;
CREATE POLICY "inventory_select_all" ON public.merchant_inventory
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "inventory_write_pro" ON public.merchant_inventory;
CREATE POLICY "inventory_write_pro" ON public.merchant_inventory
  FOR ALL TO authenticated
  USING (merchant_id = auth.uid() AND public.is_active_pro(auth.uid()))
  WITH CHECK (merchant_id = auth.uid() AND public.is_active_pro(auth.uid()));

-- 8) RLS: الزبون يعدّل/يؤرشف/يلغي طلباته فقط
DROP POLICY IF EXISTS "quote_requests_customer_update" ON public.quote_requests;
CREATE POLICY "quote_requests_customer_update" ON public.quote_requests
  FOR UPDATE TO authenticated
  USING (customer_id = auth.uid()) WITH CHECK (customer_id = auth.uid());

-- 9) دالة إدارية: تفعيل PRO لمدة 30 يوماً عند قبول الوصل
CREATE OR REPLACE FUNCTION public.approve_pro_request(req_id uuid, days int DEFAULT 30)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'not allowed';
  END IF;
  UPDATE public.subscription_requests
     SET status = 'approved', reviewed_at = now()
   WHERE id = req_id RETURNING merchant_id INTO m;
  UPDATE public.profiles
     SET is_pro = true,
         pro_expires_at = GREATEST(COALESCE(pro_expires_at, now()), now()) + make_interval(days => days)
   WHERE id = m;
END;
$$;
