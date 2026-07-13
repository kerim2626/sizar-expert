"""Веб-интерфейс экспертной системы «Конфигуратор СИЗАР»."""
from flask import Flask, render_template, request

from .engine import AREAS, CHOICES, InputError, consult, rule_names

PRESETS = {
    "office": dict(channels=40, operators=40, hours=6, retention=180, screen_retention=30, sites=1, screens="no",
                   analytics="none", availability="standard", siprec="yes", kii="no", os="any"),
    "contact": dict(channels=450, operators=420, hours=7, retention=365, screen_retention=30, sites=1, screens="yes",
                    analytics="post", availability="high", siprec="yes", kii="no", os="redos"),
    "bank": dict(channels=1200, operators=900, hours=8, retention=1095, screen_retention=14, sites=6, screens="yes",
                 analytics="realtime", availability="critical", siprec="no", kii="yes", os="astra"),
}
LABELS = {
    "screens": {"no": "нет", "yes": "да"},
    "analytics": {"none": "не нужна", "post": "после звонка (пакетная)", "realtime": "в реальном времени"},
    "availability": {"standard": "стандартная (99,5 %)", "high": "высокая (99,9 %)", "critical": "критичная (99,99 %)"},
    "siprec": {"yes": "да", "no": "нет"},
    "kii": {"no": "нет", "yes": "да"},
    "os": {"any": "без требований", "astra": "Astra Linux SE", "redos": "РЕД ОС"},
}


def create_app():
    app = Flask(__name__)

    @app.template_filter("num")
    def num(v):
        if isinstance(v, float):
            return f"{v:,.2f}".replace(",", " ").replace(".", ",")
        return f"{v:,}".replace(",", " ") if isinstance(v, int) else v

    @app.route("/", methods=["GET", "POST"])
    def index():
        form = dict(PRESETS["contact"])
        preset = request.args.get("preset")
        if preset in PRESETS:
            form = dict(PRESETS[preset])
        result, error = None, None
        if request.method == "POST":
            form = request.form.to_dict()
            try:
                result = consult(form)
            except InputError as e:
                error = str(e)
        return render_template("index.html", form=form, result=result, error=error, labels=LABELS,
                               choices=CHOICES, areas=AREAS)

    @app.route("/kb")
    def kb():
        from .engine import KB
        return render_template("kb.html", rules=rule_names(), source=KB.read_text(encoding="utf-8"))

    return app
