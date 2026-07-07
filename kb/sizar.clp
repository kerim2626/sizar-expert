;;; =====================================================================
;;; База знаний экспертной системы «Конфигуратор СИЗАР»
;;; Подбор архитектуры развертывания системы записи разговоров
;;; и речевой аналитики на серверах заказчика.
;;; Оболочка: CLIPS 6.4 (прямой логический вывод, стратегия depth).
;;; =====================================================================

;;; ---------- шаблоны фактов ----------

(deftemplate request "Исходные данные заказчика (вводятся пользователем)"
  (slot channels (type INTEGER) (range 1 100000))       ; одновременных разговоров в пике
  (slot operators (type INTEGER) (range 0 100000))      ; рабочих мест операторов
  (slot hours (type INTEGER) (range 1 24))              ; часов разговоров на канал в сутки
  (slot retention (type INTEGER) (range 1 3650))        ; срок хранения аудио, дней
  (slot screens (allowed-symbols no yes))               ; запись экранов операторов
  (slot screen-retention (type INTEGER) (default 30))   ; срок хранения видео экранов, дней
  (slot analytics (allowed-symbols none post realtime)) ; речевая аналитика
  (slot sites (type INTEGER) (range 1 500))             ; число площадок (филиалов)
  (slot availability (allowed-symbols standard high critical))
  (slot siprec (allowed-symbols yes no))                ; АТС поддерживает SIPREC
  (slot kii (allowed-symbols no yes))                   ; значимый объект КИИ
  (slot os (allowed-symbols any astra redos)))          ; требование к ОС

(deftemplate profile "Выведенный класс нагрузки и профиль развертывания"
  (slot load (allowed-symbols small medium large))
  (slot deployment (allowed-symbols compact cluster distributed)))

(deftemplate metric "Рассчитанный показатель"
  (slot name) (slot value) (slot unit) (slot order (type INTEGER) (default 50)))

(deftemplate advice "Рекомендация с объяснением"
  (slot area)                 ; architecture / sizing / integration / security / availability / analytics
  (slot text (type STRING))
  (slot why (type STRING))    ; объяснение для пользователя
  (slot rule))                ; имя сработавшего правила

;;; ---------- нормативы (факты-константы базы знаний) ----------

(deffacts norms "Нормативы, принятые экспертами"
  (norm audio-mb-per-hour 10.8)      ; Opus 24 кбит/с: 24 000 / 8 × 3600 / 10^6 = 10,8 МБ/ч
  (norm screen-mb-per-hour 54)       ; запись экрана 1 кадр/с, ~120 кбит/с
  (norm channels-per-recorder 300)   ; каналов на один узел записи SIPREC
  (norm channels-per-asr-post 150)   ; каналов на 1 GPU при пакетной расшифровке
  (norm channels-per-asr-rt 50)      ; каналов на 1 GPU при распознавании в реальном времени
  (norm storage-reserve 1.2))        ; запас 20 % на служебные данные и рост

(deffunction ceil-div (?a ?b)
  (if (= (mod ?a ?b) 0) then (div ?a ?b) else (+ (div ?a ?b) 1)))

(deffunction tb (?mb) (/ (round (* (/ ?mb 1000000.0) 100)) 100.0))

;;; ---------- 1. классификация нагрузки ----------

(defrule load-small
  (request (channels ?c&:(<= ?c 60)))
  =>
  (assert (load small)))

(defrule load-medium
  (request (channels ?c&:(and (> ?c 60) (<= ?c 600))))
  =>
  (assert (load medium)))

(defrule load-large
  (request (channels ?c&:(> ?c 600)))
  =>
  (assert (load large)))

;;; ---------- 2. профиль развертывания ----------

(defrule deploy-distributed
  (declare (salience 20))
  (request (sites ?s&:(> ?s 1)))
  (load ?l)
  (not (profile))
  =>
  (assert (profile (load ?l) (deployment distributed)))
  (assert (advice (area architecture) (rule deploy-distributed)
    (text "Распределенная схема: узлы записи SIPREC на каждой площадке, центральный кластер хранения и аналитики")
    (why (str-cat "Площадок: " ?s ". Запись рядом с АТС не нагружает каналы связи между офисами в пике, а при обрыве канала запись продолжается локально")))))

(defrule deploy-cluster
  (declare (salience 10))
  (request (sites 1) (availability ?a))
  (load ?l)
  (test (or (neq ?l small) (neq ?a standard)))
  (not (profile))
  =>
  (assert (profile (load ?l) (deployment cluster)))
  (assert (advice (area architecture) (rule deploy-cluster)
    (text "Кластер Kubernetes не менее чем из 3 узлов с размещением компонентов СИЗАР в контейнерах")
    (why (str-cat "Класс нагрузки: " ?l ", требование доступности: " ?a ". Кластер дает горизонтальное масштабирование и переживает отказ узла")))))

(defrule deploy-compact
  (request (sites 1) (availability standard))
  (load small)
  (not (profile))
  =>
  (assert (profile (load small) (deployment compact)))
  (assert (advice (area architecture) (rule deploy-compact)
    (text "Компактная установка: один сервер, компоненты в Docker Compose")
    (why "До 60 одновременных разговоров на одной площадке без повышенных требований к доступности — кластер избыточен"))))

;;; ---------- 3. расчет ресурсов ----------

(defrule size-recorders
  (request (channels ?c) (sites ?s))
  (profile (deployment ?d))
  (norm channels-per-recorder ?n)
  =>
  (bind ?nodes (ceil-div ?c ?n))
  (if (eq ?d distributed) then (bind ?nodes (max ?nodes ?s)))
  (if (eq ?d cluster) then (bind ?nodes (max ?nodes 2)))
  (assert (metric (name "Узлы записи SIPREC") (value ?nodes) (unit "шт.") (order 10)))
  (assert (advice (area sizing) (rule size-recorders)
    (text (str-cat "Узлов записи: " ?nodes))
    (why (str-cat "Норматив " ?n " одновременных каналов на узел; пик " ?c " каналов"
                  (if (eq ?d cluster) then "; в кластере не менее 2 узлов для резерва" else "")
                  (if (eq ?d distributed) then "; не меньше числа площадок" else ""))))))

(defrule size-audio-storage
  (request (channels ?c) (hours ?h) (retention ?r))
  (norm audio-mb-per-hour ?mb)
  (norm storage-reserve ?k)
  =>
  (bind ?total (* ?c ?h ?r ?mb ?k))
  (assert (metric (name "Хранилище аудио") (value (tb ?total)) (unit "ТБ") (order 20)))
  (assert (advice (area sizing) (rule size-audio-storage)
    (text (str-cat "Объем хранилища аудиозаписей: " (tb ?total) " ТБ"))
    (why (str-cat ?c " каналов × " ?h " ч/сут × " ?r " дн. × " ?mb " МБ/ч (Opus 24 кбит/с) × запас " ?k)))))

(defrule size-screen-storage
  (request (screens yes) (operators ?o&:(> ?o 0)) (hours ?h) (screen-retention ?r))
  (norm screen-mb-per-hour ?mb)
  =>
  (bind ?total (* ?o ?h ?r ?mb))
  (assert (metric (name "Хранилище видео экранов") (value (tb ?total)) (unit "ТБ") (order 30)))
  (assert (advice (area sizing) (rule size-screen-storage)
    (text (str-cat "Объем хранилища записи экранов: " (tb ?total) " ТБ (срок " ?r " дн.)"))
    (why "Видео экрана в 5 раз объемнее аудио, поэтому его хранят короче, чем звонки"))))

(defrule screens-without-operators
  (request (screens yes) (operators 0))
  =>
  (assert (advice (area sizing) (rule screens-without-operators)
    (text "Запись экранов выбрана, но число операторов равно 0 — объем видео не рассчитан")
    (why "Проверьте исходные данные"))))

(defrule size-asr
  (request (channels ?c) (analytics ?a&~none))
  (norm channels-per-asr-post ?np)
  (norm channels-per-asr-rt ?nr)
  =>
  (bind ?n (if (eq ?a realtime) then ?nr else ?np))
  (bind ?gpu (ceil-div ?c ?n))
  (assert (metric (name "GPU-серверы распознавания речи") (value ?gpu) (unit "шт.") (order 40)))
  (assert (advice (area analytics) (rule size-asr)
    (text (str-cat "Серверов с GPU для речевой аналитики: " ?gpu))
    (why (str-cat (if (eq ?a realtime) then "Распознавание в реальном времени: " else "Пакетная расшифровка после звонка: ")
                  ?n " каналов на 1 GPU")))))

(defrule analytics-realtime-latency
  (request (analytics realtime))
  =>
  (assert (advice (area analytics) (rule analytics-realtime-latency)
    (text "Разместить сервис распознавания в том же сегменте сети, что и узлы записи")
    (why "Подсказки оператору в реальном времени требуют задержки менее 1 с"))))

;;; ---------- 4. интеграция с телефонией ----------

(defrule integration-siprec
  (request (siprec yes))
  =>
  (assert (advice (area integration) (rule integration-siprec)
    (text "Подключение к АТС по протоколу SIPREC (RFC 7866): АТС отправляет копию медиапотока в СИЗАР")
    (why "АТС поддерживает SIPREC — это штатный способ записи без изменения маршрутизации вызовов"))))

(defrule integration-no-siprec
  (request (siprec no))
  =>
  (assert (advice (area integration) (rule integration-no-siprec)
    (text "Пассивная запись через зеркалирование портов (SPAN) либо обновление АТС до версии с SIPREC")
    (why "Без SIPREC система не получает копию разговора от АТС; зеркалирование трафика не требует изменений на АТС, но не работает с шифрованным SRTP"))))

;;; ---------- 5. безопасность и регуляторные требования ----------

(defrule security-baseline
  (request)
  =>
  (assert (advice (area security) (rule security-baseline)
    (text "Ролевая модель доступа, шифрование записей при хранении, журнал действий в SIEM по Syslog, предупреждение абонента о записи")
    (why "Запись разговоров содержит персональные данные (152-ФЗ) и защищается тайной связи; утечка ПДн влечет оборотные штрафы по ст. 13.11 КоАП"))))

(defrule security-kii
  (request (kii yes))
  =>
  (assert (advice (area security) (rule security-kii)
    (text "Развернуть на сертифицированной ОС из реестра (Astra Linux Special Edition) в выделенном сегменте с СЗИ")
    (why "На значимых объектах КИИ используется только российское ПО из реестра; иностранное ПО запрещено с 01.01.2025 (Указ № 166)"))))

(defrule os-astra
  (request (os astra))
  =>
  (assert (advice (area security) (rule os-astra)
    (text "Использовать сборку СИЗАР для Astra Linux SE 1.8 (подтверждена сертификатом совместимости)")
    (why "Требование заказчика к ОС"))))

(defrule os-redos
  (request (os redos))
  =>
  (assert (advice (area security) (rule os-redos)
    (text "Использовать сборку СИЗАР для РЕД ОС (подтверждена сертификатом совместимости)")
    (why "Требование заказчика к ОС"))))

;;; ---------- 6. доступность ----------

(defrule availability-high
  (request (availability high))
  =>
  (assert (metric (name "Коэффициент репликации хранилища") (value 2) (unit "") (order 60)))
  (assert (advice (area availability) (rule availability-high)
    (text "Хранилище MinIO с двумя копиями данных, резервный узел записи, мониторинг заполнения дисков (порог 80 %)")
    (why "Цель 99,9 % — не более 8,8 ч простоя в год"))))

(defrule availability-critical
  (request (availability critical))
  =>
  (assert (metric (name "Коэффициент репликации хранилища") (value 3) (unit "") (order 60)))
  (assert (advice (area availability) (rule availability-critical)
    (text "Два ЦОД в режиме active-active, репликация хранилища между площадками, автоматическое переключение узлов записи")
    (why "Цель 99,99 % — не более 53 мин простоя в год; отказ одного ЦОД не должен останавливать запись"))))

(defrule availability-compact-warning
  (profile (deployment compact))
  =>
  (assert (advice (area availability) (rule availability-compact-warning)
    (text "Ежедневное резервное копирование записей на отдельный носитель")
    (why "У компактной установки нет резервного сервера: при отказе диска записи будут потеряны без копии"))))

;;; ---------- 7. итоговая проверка противоречий ----------

(defrule conflict-compact-large-retention
  (profile (deployment compact))
  (metric (name "Хранилище аудио") (value ?v&:(> ?v 20)))
  =>
  (assert (advice (area architecture) (rule conflict-compact-large-retention)
    (text "Объем хранилища больше 20 ТБ — вынести записи на сетевое хранилище или перейти на кластер")
    (why "Один сервер с локальными дисками плохо масштабируется при таком объеме"))))
