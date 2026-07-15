"""Тестирование базы знаний: проверочные сценарии с заранее рассчитанным ответом эксперта."""
import unittest

from es import create_app
from es.engine import InputError, consult, rule_names

BASE = dict(channels=40, operators=40, hours=6, retention=180, screen_retention=30, sites=1, screens="no",
            analytics="none", availability="standard", siprec="yes", kii="no", os="any")


def run(**kw):
    return consult(dict(BASE, **kw))


def metric(r, name):
    return {m["name"]: m["value"] for m in r.metrics}.get(name)


class EngineTests(unittest.TestCase):
    def test_kb_loads(self):
        self.assertEqual(len(rule_names()), 22)

    def test_small_office_compact(self):
        r = run()
        self.assertEqual(r.profile["code"], "compact")
        self.assertIn("availability-compact-warning", r.fired)
        self.assertEqual(metric(r, "Узлы записи SIPREC"), 1)
        self.assertAlmostEqual(metric(r, "Хранилище аудио"), 0.56)      # 40·6·180·10,8·1,2 = 559 872 МБ

    def test_boundary_60_and_61_channels(self):
        self.assertEqual(run(channels=60).profile["code"], "compact")
        self.assertEqual(run(channels=61).profile["code"], "cluster")

    def test_small_load_high_availability_gives_cluster(self):
        r = run(availability="high")
        self.assertEqual(r.profile["code"], "cluster")
        self.assertEqual(metric(r, "Узлы записи SIPREC"), 2)            # минимум 2 узла в кластере
        self.assertEqual(metric(r, "Коэффициент репликации хранилища"), 2)

    def test_contact_center(self):
        r = run(channels=450, operators=420, hours=7, retention=365, screens="yes", analytics="post", availability="high", os="redos")
        self.assertEqual(r.profile["code"], "cluster")
        self.assertAlmostEqual(metric(r, "Хранилище аудио"), 14.9)
        self.assertAlmostEqual(metric(r, "Хранилище видео экранов"), 4.76)
        self.assertEqual(metric(r, "GPU-серверы распознавания речи"), 3)
        self.assertIn("os-redos", r.fired)

    def test_distributed_bank_kii(self):
        r = run(channels=1200, operators=900, hours=8, retention=1095, screen_retention=14, sites=6, screens="yes",
                analytics="realtime", availability="critical", siprec="no", kii="yes", os="astra")
        self.assertEqual(r.profile["code"], "distributed")
        self.assertEqual(metric(r, "Узлы записи SIPREC"), 6)            # max(⌈1200/300⌉, 6 площадок)
        self.assertEqual(metric(r, "GPU-серверы распознавания речи"), 24)
        for rule in ("security-kii", "integration-no-siprec", "analytics-realtime-latency", "availability-critical"):
            self.assertIn(rule, r.fired)

    def test_each_rule_fires_once(self):
        r = run(channels=1200, sites=6, screens="yes", analytics="realtime", availability="critical", kii="yes")
        self.assertEqual(len(r.fired), len(set(r.fired)))
        self.assertEqual(len([a for a in r.advice if a["area"] == "architecture"]), 1)

    def test_screens_without_operators(self):
        r = run(screens="yes", operators=0)
        self.assertIn("screens-without-operators", r.fired)
        self.assertIsNone(metric(r, "Хранилище видео экранов"))

    def test_compact_large_storage_conflict(self):
        r = run(channels=60, hours=24, retention=3650)
        self.assertIn("conflict-compact-large-retention", r.fired)

    def test_decimal_comma_in_texts(self):
        r = run()
        text = " ".join(a["text"] for a in r.advice)
        self.assertIn("0,56 ТБ", text)
        why = " ".join(a["why"] for a in run(kii="yes", os="astra").advice)
        self.assertIn("01.01.2025", why)                                 # дата не испорчена заменой
        self.assertIn("× запас 1,2", why)

    def test_input_validation(self):
        for bad in (dict(channels="abc"), dict(channels=0), dict(hours=25), dict(analytics="magic"), dict(sites=-1)):
            with self.assertRaises(InputError):
                run(**bad)

    def test_web_interface(self):
        c = create_app().test_client()
        self.assertEqual(c.get("/?preset=bank").status_code, 200)
        html = c.post("/", data=dict(BASE, channels="450", availability="high")).get_data(as_text=True)
        self.assertIn("Кластер Kubernetes", html)
        self.assertIn("Почему:", html)
        self.assertIn("допустимо", c.post("/", data=dict(BASE, hours="30")).get_data(as_text=True))
        self.assertIn("deploy-cluster", c.get("/kb").get_data(as_text=True))


if __name__ == "__main__":
    unittest.main()
