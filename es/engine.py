"""Механизм логического вывода: связка Python ↔ CLIPS (clipspy)."""
import re
from dataclasses import dataclass, field
from pathlib import Path

import clips

KB = Path(__file__).resolve().parent.parent / "kb" / "sizar.clp"

AREAS = {
    "architecture": "Архитектура",
    "sizing": "Ресурсы",
    "analytics": "Речевая аналитика",
    "integration": "Интеграция с АТС",
    "security": "Безопасность",
    "availability": "Отказоустойчивость",
}
DEPLOYMENT = {"compact": "Компактная установка", "cluster": "Кластер Kubernetes", "distributed": "Распределенная схема"}
LOAD = {"small": "малая (до 60 каналов)", "medium": "средняя (61–600 каналов)", "large": "высокая (более 600 каналов)"}

CHOICES = {
    "screens": ("no", "yes"), "analytics": ("none", "post", "realtime"),
    "availability": ("standard", "high", "critical"), "siprec": ("yes", "no"),
    "kii": ("no", "yes"), "os": ("any", "astra", "redos"),
}
LIMITS = {"channels": (1, 100000), "operators": (0, 100000), "hours": (1, 24), "retention": (1, 3650),
          "screen_retention": (1, 365), "sites": (1, 500)}


class InputError(ValueError):
    pass


@dataclass
class Result:
    profile: dict
    metrics: list
    advice: list
    fired: list = field(default_factory=list)

    def by_area(self):
        out = {}
        for a in self.advice:
            out.setdefault(a["area"], []).append(a)
        return [(AREAS[k], out[k]) for k in AREAS if k in out]


def ru_num(text):
    """CLIPS выводит дробные числа с точкой. Заменяем точку на запятую только у величин с единицами
    измерения и у коэффициента запаса: даты (01.01.2025) и версии (1.8) не трогаем."""
    text = re.sub(r"(\d)\.(\d+)(?=\s*(?:ТБ|МБ|ГБ|кбит|%))", r"\1,\2", str(text))
    return re.sub(r"(запас )(\d+)\.(\d+)", r"\1\2,\3", text)


def validate(form):
    data = {}
    for key, (lo, hi) in LIMITS.items():
        raw = str(form.get(key, "")).strip()
        if not raw.lstrip("-").isdigit():
            raise InputError(f"Поле «{key}»: нужно целое число")
        val = int(raw)
        if not lo <= val <= hi:
            raise InputError(f"Поле «{key}»: допустимо от {lo} до {hi}")
        data[key] = val
    for key, allowed in CHOICES.items():
        val = str(form.get(key, allowed[0]))
        if val not in allowed:
            raise InputError(f"Поле «{key}»: недопустимое значение")
        data[key] = val
    return data


def consult(form):
    """Провести консультацию: загрузить базу знаний, добавить факт-запрос, выполнить вывод."""
    data = validate(form)
    env = clips.Environment()
    env.load(str(KB))
    env.reset()                                       # загружает deffacts с нормативами
    env.assert_string(
        "(request (channels {channels}) (operators {operators}) (hours {hours}) (retention {retention}) "
        "(screens {screens}) (screen-retention {screen_retention}) (analytics {analytics}) (sites {sites}) "
        "(availability {availability}) (siprec {siprec}) (kii {kii}) (os {os}))".format(**data))
    env.run()
    profile, metrics, advice = {}, [], []
    for f in env.facts():
        name = f.template.name
        if name == "profile":
            profile = {"load": LOAD[str(f["load"])], "deployment": DEPLOYMENT[str(f["deployment"])],
                       "code": str(f["deployment"])}
        elif name == "metric":
            metrics.append({"name": f["name"], "value": f["value"], "unit": f["unit"], "order": f["order"]})
        elif name == "advice":
            advice.append({"area": str(f["area"]), "text": ru_num(f["text"]), "why": ru_num(f["why"]), "rule": str(f["rule"])})
    metrics.sort(key=lambda m: m["order"])
    # одна метрика с одинаковым именем (страховка от повторной активации правил)
    seen, uniq = set(), []
    for m in metrics:
        if m["name"] not in seen:
            seen.add(m["name"]); uniq.append(m)
    return Result(profile=profile, metrics=uniq, advice=advice, fired=[a["rule"] for a in advice])


def rule_names():
    env = clips.Environment()
    env.load(str(KB))
    return [r.name for r in env.rules()]
