<p align="center">
  <img src="./assets/readme/hero-ru.svg" width="100%" alt="superpowers-strigov-ver — многомодельный delivery control plane для Claude Code">
</p>

<p align="center">
  <a href="./README.md"><strong>Read in English</strong></a>
  ·
  <a href="#быстрый-старт">Быстрый старт</a>
  ·
  <a href="#протокол-разработки">Протокол</a>
  ·
  <a href="#роли-моделей">Модели</a>
  ·
  <a href="#что-входит-в-плагин">Состав</a>
</p>

<p align="center">
  <img alt="Версия 0.12.0" src="https://img.shields.io/badge/version-0.12.0-7c8cff?style=flat-square">
  <img alt="Плагин Claude Code" src="https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square">
  <img alt="Лицензия MIT" src="https://img.shields.io/badge/license-MIT-35d6a6?style=flat-square">
</p>

`superpowers-strigov-ver` превращает Claude Code в структурированную систему разработки. Одна модель оркестрирует процесс, специализированные модели планируют и пишут код, независимые ревьюеры проверяют результат, а каждая важная передача оставляет долговечный артефакт.

> **Результат:** длинные задачи переживают compaction контекста, циклы ревью остаются ограниченными, а код не считается готовым, пока не пройдены гейты фазы и всей ветки.

## Быстрый старт

### 1. Установите зависимости

Нужны актуальный **Claude Code**, отдельный **Codex CLI** и однократный вход в Codex:

```bash
npm install -g @openai/codex
codex login
```

Необязательно — имплементер по умолчанию, **GLM-5.3-Flash через ZCode от Z.ai**: установите [ZCode](https://github.com/zai-org/ZCode) — macOS: ZCode.app в `/Applications`; Linux: см. [Linux: ZCode для канала GLM](#linux-zcode-для-канала-glm) ниже; Windows пока не поддерживается — и один раз сохраните API-ключ GLM Coding Plan со страницы <https://z.ai/manage-apikey/apikey-list>: выполните в терминале `zcode-dispatch api-key set` и вставьте ключ в скрытое приглашение. Ключ станет провайдером собственного шаблона ZCode «Z.ai Coding Plan» в приватном конфиге обёртки и не истекает. OAuth-входа нет: `zcode login` в CLI не хранит refresh-токен и живёт около часа (подробности — в скилле `zcode-invocation`, раздел «One-time setup»). Без ключа `zcode-dispatch doctor` не проходит, и пайплайн реализует фазы на Codex Luna `max` — с объявлением, никогда молча. За локальным прокси экспортируйте `ZCODE_HTTP_PROXY=http://<host>:<port>`, если фоновые запуски падают с сетевой ошибкой (CLI игнорирует `HTTP(S)_PROXY` и системный прокси macOS; обёртка передаёт эту переменную через белый список). CLI получает окружение по белому списку; дополнительные переменные можно явно передать через `ZCODE_ENV_PASSTHROUGH="NAME1,NAME2"`.

#### Linux: ZCode для канала GLM

У Z.ai есть официальная Linux-сборка ZCode (бета) на <https://zcode.z.ai> (раздел «All Downloads»: `.deb`, `.rpm` и `.AppImage` для x64 и ARM64). Пакеты `.deb` и `.rpm` ставятся в `/opt/ZCode` — именно там `zcode-dispatch` ищет ZCode по умолчанию. Проверено со всеми официальными пакетами 3.16.2 (CLI 0.17.0, одинаковый во всех шести): `.deb` на Debian 12 (arm64 и x64), `.rpm` на Fedora 42 и распакованный `.AppImage` (arm64). Во всех случаях `doctor` проходит, а пробный запрос доходит до Z.ai.

Шаги для вашего агента (Claude Code на Linux-машине):

1. Проверить зависимости: `node --version` (мажорная версия ≥ 26; обёртка запускает CLI системным `node`, а не Electron'ом приложения), `flock --version` (пакет util-linux, поставить, если нет), `git --version`.
2. Поставить ZCode. Сначала спросить пользователя: нужен sudo и скачивание около 170 МБ. Ссылку под архитектуру машины (`uname -m`: `x86_64` → x64, `aarch64` → ARM64) взять в разделе «All Downloads» на <https://zcode.z.ai>. Дальше:
   - Debian/Ubuntu: `sudo apt install ./ZCode-<версия>-linux-<arch>.deb`
   - Fedora/RHEL/openSUSE: `sudo dnf install ./ZCode-<версия>-linux-<arch>.rpm` (или `zypper install`)
   - Без sudo: скачать `.AppImage`, в выбранном каталоге выполнить `chmod +x ZCode-*.AppImage && ./ZCode-*.AppImage --appimage-extract` и прописать в `~/.claude/settings.json` `"env": { "ZCODE_APP": "<каталог>/squashfs-root" }`, чтобы этот путь видел каждый вызов `zcode-dispatch`. (Распаковка не требует ни FUSE, ни sudo. После неё должен существовать файл `squashfs-root/resources/glm/zcode.cjs`.)
3. Проверить. Ниже `<корень>` — это `/opt/ZCode` для `.deb`/`.rpm` или `<каталог>/squashfs-root` для AppImage. `doctor` нужен git-репозиторий, поэтому запускать его из репозитория, в котором будет работать пайплайн, или передавать `--cwd <репо>`:
   - `node <корень>/resources/glm/zcode.cjs --version` печатает версию CLI;
   - `zcode-dispatch doctor --cwd <репо>` показывает `ok platform: linux (config lock: flock(1))` и `ok app: <корень> <версия>`.

   На этом этапе падать могут только `personal-config` и `auth`: ключ ещё не сохранён. `WARN app-version` значит, что установленная версия отличается от той, на которой проверялась обёртка; это нормально, если проба на шаге 4 проходит. Если версию прочитать не удалось, `doctor` падает на `app`.
4. Шаг с API-ключом передать пользователю. Никогда не просить ключ в чате. Дать пользователю одну готовую команду для его терминала с абсолютным путём к `zcode-dispatch`. При установке из AppImage добавить префикс `ZCODE_APP=<корень>`, потому что его shell не видит `settings.json` Claude Code:

   ```
   /path/to/bin/zcode-dispatch api-key set                                              # .deb / .rpm
   ZCODE_APP=/home/<user>/apps/squashfs-root /path/to/bin/zcode-dispatch api-key set    # AppImage
   ```

   Пользователь запускает её и вставляет ключ в скрытое приглашение. После этого выполнить `zcode-dispatch doctor --probe --cwd <репо>` (один короткий запрос): `probe: ok` значит, что канал GLM работает.

Примечания:
- Пакет также кладёт в `PATH` команду `/usr/bin/zcode`. Это запуск десктопного приложения, а не CLI; обёртка её не использует.
- Не ставить сторонние пакеты ZCode CLI (например, `zcode-app-cli` из npm).
- За прокси экспортировать `ZCODE_HTTP_PROXY` (см. выше).
- Если официальный пакет не подходит (например, неподдерживаемый дистрибутив), можно скопировать `resources/{glm,config,app.asar}` из установки ZCode той же версии на macOS (`/Applications/ZCode.app/Contents/Resources`) или Windows в `/opt/ZCode/resources/`.

### 2. Установите плагин

Выполните в Claude Code:

```text
/plugin marketplace add strigov/strigov-cc-plugins
/plugin install superpowers-strigov-ver@strigov-cc-plugins
/reload-plugins
```

Companion runtime уже вендорится. Отдельный Claude Code-плагин OpenAI `codex-plugin-cc` **не нужен**.

### 3. Запустите реальную задачу

```text
/dev Реализуй возобновляемую загрузку файлов с проверкой целостности
```

Пайплайн не запускается самостоятельно. Запустите его командой `/dev` или сначала вызовите `/superpowers-strigov-ver:brainstorming`, чтобы согласовать дизайн. Чтобы продолжить незавершённый план в новой сессии, запустите `/dev` без задачи или просто попросите продолжить: тихий SessionStart-хук назовёт план. Внутри пайплайна `dev-orchestrator` выполняет триаж, а тривиальные правки одного файла идут по облегчённому пути Sonnet quickfix.

## Что меняется

| Обычный агентный процесс | Этот плагин |
|---|---|
| Одна модель планирует, пишет и сама оценивает свою работу | Каждый артефакт пишут и ревьюят разные модельные семейства |
| Прогресс живёт в основном в контексте чата | Планы, ledger, отчёты, diff и task ID позволяют возобновлять работу |
| Ревью может расширять scope или циклиться | Правила авторизации, детекторы churn и жёсткие лимиты ограничивают каждый цикл |
| Зелёная фаза может скрывать интеграционные ошибки | Финальное ревью всей ветки проверяет контракты и запускает полный suite |

## Протокол разработки

<p align="center">
  <img src="./assets/readme/workflow-ru.svg" width="100%" alt="Шестиэтапный протокол от плана до финального гейта всей ветки">
</p>

1. **План** — Opus-субагент на `xhigh` исследует репозиторий и пишет долговечный план со scope, интерфейсами, глобальными ограничениями, тестами, рисками и явной меткой SECURITY/DATA_LOSS для каждой фазы.
2. **Критика** — свежее ревью Codex Astra `xhigh` ищет материальные пробелы, в том числе пропущенные метки риска; разрешённые правки уходят свежему Opus `high` через ledger.
3. **Реализация** — GLM-5.3-Flash `max` реализует одну фазу через собственный ZCode CLI от Z.ai и пишет отчёт. Codex Luna `max` подхватывает работу, если канал GLM недоступен или выключен; Sol 6.1 `xhigh` с самого начала реализует фазы с меткой SECURITY/DATA_LOSS и подхватывает работу, когда диагностика Opus, застрявший гейт или третий заблокированный раунд ревью требуют более глубокого reasoning.
4. **Верификация** — Sonnet-гейт на `medium` запускает lint, typecheck и затронутые тесты до начала дорогого ревью.
5. **Два ревью** — Opus `high` проверяет соответствие плану и качество (`xhigh` на фазах SECURITY/DATA_LOSS и в последнем раунде), затем свежий Codex Astra `high` ищет граничные случаи, гонки, уязвимости и регрессии.
6. **Гейт ветки** — после всех фаз свежий Opus `xhigh` проверяет всю ветку и полный набор тестов (Astra `xhigh`, если Opus недоступен). До финального вердикта разрешена одна объединённая волна фиксов.

Каждое продолжение имплементера адресуется по id через `--resume-task` — `task-…` для тредов Codex, `zt-…` для сессий ZCode. Ревьюеры получают сгенерированный пакет со списком коммитов, статистикой и контекстным diff, а не восстанавливают изменения из истории чата.

## Роли моделей

У каждой роли закреплена пара «модель + effort». Claude-субагенты получают явный `effort` в вызове Agent (без `ultrathink`); задачи Codex — явные `--model` и `--effort`.

| Роль | Модель · effort |
|---|---|
| Оркестратор (главный тред) | Claude Sonnet · `medium` |
| Автор плана / спеки | Claude Opus · `xhigh` |
| Ревизия плана и спеки | Claude Opus · `high` |
| Ревьюер плана и спеки | GPT-6 Astra · `xhigh` |
| Имплементер, fix-раунды, финальная волна фиксов | GLM-5.3-Flash · `max` через ZCode CLI от Z.ai |
| Резерв по доступности (GLM недоступен или выключен) | GPT-6 Luna · `max` |
| Фазы SECURITY/DATA_LOSS, эскалация reasoning | GPT-6.1 Sol · `xhigh` |
| Фронтенд-имплементер | Claude Opus · `high` (новый UI) / Claude Sonnet · `medium` (мелкие правки) |
| Основное ревью кода (4.1) | Claude Opus · `high`; `xhigh` на фазах SECURITY/DATA_LOSS и в раунде 4 |
| Контрольное ревью (4.2) | GPT-6 Astra · `high` |
| Финальное ревью ветки | Claude Opus · `xhigh`; GPT-6 Astra · `xhigh`, если Opus недоступен |
| Диагностика BLOCKED и застрявшего гейта, сводка по тупику (impasse) | Claude Opus · `high` |
| Гейт верификации, синтез, quickfix, integration check | Claude Sonnet · `medium` |

`max` зарезервирован за имплементерами GLM и Luna (или по явному запросу пользователя); `ultra` никогда не выбирается автоматически — только по явному запросу пользователя. Квота GLM: 2026-10-14 бонус 1.5× для ZCode по замеру не определён (ожидаемые/списанные кредиты = 3.02 по стандартному тарифу или 1.51, если окно пришлось на непиковые часы; подробности в docs/zcode-cli-findings.md).

Эта таблица — встроенная схема: без `config.json` работает ровно она. Любую роль можно переназначить на свой профиль — см. [Свои харнессы и API](#свои-харнессы-и-api).

## Свои харнессы и API

`bin/agent-dispatch` назначает ролям пайплайна **профили**. Профиль — это харнесс, способ оплаты (собственный вход харнесса или API-ключ), модель и effort. У роли **цепочка** профилей: первый — основной, остальные — запасные, по порядку. Без файла настроек ничего не меняется.

В этом выпуске (0.12.0) есть слой маршрутизации: профили, ключи, `route`, `doctor`, статус задач и сквозной вызов ZCode и Codex. Уже сейчас роли, которые исполняются в сессии, можно перевести на другую модель или effort Claude, а внешние роли — на другие модели Codex. Адаптеры для `claude -p`, DeepSeek Harness (`dsh`), OpenCode и pi появятся в следующих выпусках. До тех пор профиль на таком харнессе получает отказ `harness <h> is not available in this version`, и оркестратор переходит к следующему профилю цепочки.

`agent-dispatch` лежит в каталоге `bin/` плагина. В своём терминале вызывайте его по абсолютному пути — Claude подскажет его.

### Профиль за три шага

```bash
agent-dispatch preset list                                          # что можно скопировать
agent-dispatch profile add deepseek-claude --from claude-deepseek   # 1. профиль из пресета
agent-dispatch key set deepseek                                     # 2. ключ, скрытым вводом
agent-dispatch doctor --profile deepseek-claude --probe             # 3. проверки без модели + один короткий платный запрос
```

1. `profile add <имя> --from <пресет> [--model M] [--key K] [--set k=v]` копирует пресет в `config.json`. Если в пресете есть заполнитель `<…>`, его нужно заполнить флагом, иначе профиль не запишется.
2. Ключ вы кладёте сами, в своём терминале: `key set <имя>` запрашивает его скрытым вводом. Из сессии Claude Code ключ можно передать через pipe: `! pbpaste | agent-dispatch key set <имя>`, на Linux — `wl-paste` или `xclip -o -selection clipboard`. Ключ, переданный аргументом, отвергается. Профиль с `login` пользуется собственным входом харнесса. Для профиля с отдельным изолированным каталогом сначала выполните `eval "$(agent-dispatch profile env <имя>)"`.
3. `doctor --profile <имя>` проверяет всё, что можно проверить без вызова модели. `--probe` добавляет один короткий платный запрос на вашем ключе или подписке; его запускаете вы, пайплайн — никогда.

В 0.12.0 все пресеты рассчитаны на `claude`, `dsh`, OpenCode или pi, поэтому шаг 3 этого примера пока заканчивается строкой `harness claude is not available in this version`: он пройдёт, когда выйдет адаптер этого харнесса. Профили, которые работают уже сейчас, пишутся вручную: другая модель или effort Codex либо другая модель Claude в сессии. Например, более дешёвое контрольное ревью и автор плана на Sonnet:

```json
{
  "version": 1,
  "profiles": {
    "astra-medium": { "harness": "codex",  "model": "gpt-6-astra", "effort": "medium" },
    "sonnet-high":  { "harness": "inproc", "model": "sonnet",      "effort": "high" }
  },
  "roles": {
    "control-review": ["astra-medium"],
    "plan-writer":    ["sonnet-high"]
  }
}
```

**Где это лежит.** Ваши профили и роли хранятся в `~/.claude/plugins/data/superpowers-strigov-ver-agents/config.json`. У каталога права 0700, а в файле нет секретов: ключи лежат в `keys/<имя>` с правами 0600.

- В файле обязательно поле `"version": 1`.
- Ваши профили добавляются к встроенным. Встроенные профили переопределить нельзя: `glm`, `luna`, `sol`, `astra`, `astra-high`, `opus-xhigh`, `opus-high` и `sonnet-medium`. Чтобы изменить такой профиль, скопируйте его под новым именем.
- Роль из файла, `"roles": { "<роль>": ["<профиль>", …] }`, целиком заменяет встроенную цепочку этой роли. Остальные роли остаются встроенными.
- Неизвестное поле или роль со ссылкой на несуществующий профиль отвергаются с их именем, так что опечатка вроде `efort` не пройдёт молча. О битом файле сообщает одна строка `config:`, и оркестратор задаёт вам один вопрос.

**Ключи из других мест.**

- По умолчанию (`{"key": "<имя>"}`) ключ читается из хранилища выше.
- Ключ, уже экспортированный в вашем шелле, передаётся только как `{"keyEnv": "VAR"}`. Без этого белый список окружения его срежет.
- Менеджер паролей подключается через `{"keyCmd": [...]}`:
  - macOS: `["security", "find-generic-password", "-w", "-s", "deepseek"]`
  - Linux: `["secret-tool", "lookup", "service", "deepseek"]`
  - любая ОС: `["op", "read", "op://…"]`

Ключ попадает только в окружение процесса харнесса — не в его argv, не в файлы настроек и не в чат. Пайплайн никогда не запускает `key set` и не просит у вас ключ.

Профили с общим ключом, общим входом харнесса (вход OpenCode или pi считается отдельно для каждого провайдера) или общей меткой `shares` выбывают вместе при `auth` или `quota`. У встроенного `glm` метка `zai-coding-plan`, поэтому запасной профиль с API Z.ai и той же меткой не упрётся в ту же исчерпанную квоту.

### Маршрутизация ролей

| Роль (имя в `config.json`) | Где в пайплайне | По умолчанию | Исполнение |
|---|---|---|---|
| `plan-writer` | автор плана | `opus-xhigh` | в сессии (Agent tool) |
| `plan-reviser` | правки плана | `opus-high` | в сессии |
| `plan-reviewer` | ревью плана (цикл до 4) | `astra` | внешний харнесс |
| `spec-reviewer` | ревью спецификации в brainstorming | `astra` | внешний харнесс |
| `implementer` | не-фронтенд фазы, fix, gate-fix, финальная волна фиксов, починка интеграции | `glm`, `luna` | внешний харнесс |
| `implementer.risk` | фазы SECURITY/DATA_LOSS | `sol` | внешний харнесс |
| `implementer.escalation` | эскалация на более глубокое рассуждение | `sol` | внешний харнесс |
| `frontend.new-ui` | фронтенд-фазы с новым UI | `opus-high` | в сессии |
| `frontend.tweak` | правки существующего фронтенда | `sonnet-medium` | в сессии |
| `gate` | lint, typecheck, затронутые тесты | `sonnet-medium` | в сессии |
| `phase-review` | ревью фазы 4.1 | `opus-high` | в сессии |
| `phase-review.escalated` | ревью фазы 4.1 на рисковых фазах и в раунде 4 | `opus-xhigh` | в сессии |
| `control-review` | контрольное ревью 4.2 | `astra-high` | внешний харнесс |
| `synthesis` | сводка ревью | `sonnet-medium` | в сессии |
| `final-review` | финальное ревью ветки | `opus-xhigh`, `astra` | в сессии, затем внешний харнесс |
| `diagnosis` | BLOCKED, застрявший гейт | `opus-high` | в сессии |
| `quickfix` | тривиальные правки | `sonnet-medium` | в сессии |
| `integration-check` | проверка интеграции параллельной группы | `sonnet-medium` | в сессии |
| `adhoc-review` | `requesting-code-review`, второе мнение в `systematic-debugging` | `astra-high` | внешний харнесс |

`frontend.new-ui` и `frontend.tweak` — две роли, а не цепочка: между ними, как и раньше, выбирает триаж.

Пример для тех, у кого нет OpenAI:

```json
"roles": {
  "implementer":            ["glm", "deepseek-dsh"],
  "implementer.risk":       ["claude-sub"],
  "implementer.escalation": ["claude-sub"],
  "plan-reviewer":          ["deepseek-claude", "oc-copilot"],
  "spec-reviewer":          ["deepseek-claude"],
  "control-review":         ["deepseek-claude", "glm-api"],
  "final-review":           ["opus-xhigh", "deepseek-claude"],
  "adhoc-review":           ["deepseek-claude"]
}
```

- При сбое GLM фаза уходит на `deepseek-dsh`, а не на Luna.
- Рисковые фазы и эскалации идут на Opus через подписку Claude.
- Ревьюеры работают на DeepSeek, а запасные — Copilot и API GLM.

Ещё о маршрутизации:

- **Роли в сессии.** Их можно назначить на свои `inproc`-профили, то есть на другую модель или effort Claude. Например, на Claude Pro можно задать `"sonnet-high": { "harness": "inproc", "model": "sonnet", "effort": "high" }` и `"plan-writer": ["sonnet-high"]`. Запуск этих ролей на внешних харнессах появится в одном из следующих выпусков. До тех пор `route` берёт из такой цепочки только профили для сессии (а если их нет — встроенный профиль) и печатает одну строку-пояснение. `final-review` тоже начинается в сессии: его профили для сессии всегда идут первыми (если вы их не задали — `opus-xhigh`), а внешние профили запускаются только после них, как запасные, в каком бы порядке вы их ни записали. Поэтому `"final-review": ["astra"]` всё равно начнётся на `opus-xhigh`, а `route --all` напечатает `routes: default` и пояснение: он сравнивает цепочки, которые действительно будут работать.
- **Как пайплайн читает маршруты.**
  - При старте и после сжатия контекста оркестратор вызывает `agent-dispatch route --all`. Ответ `routes: default` не объявляется. Иначе вы получите одну строку с вашими отличиями.
  - Перед каждой отправкой ревьюеру, при первой отправке фазы имплементеру и при каждой смене профиля он вызывает `route <роль>`, поэтому ничего не нужно помнить. Повторы и раунды исправлений фазы остаются на её текущем профиле.
  - После `routes: default` эти вызовы не делаются, и отвечает встроенная схема — пока вы не скажете в сессии «без <профиль>» о каком-либо профиле, кроме GLM.
  - Переход на следующий профиль цепочки объявляется одной строкой, например `Channel implementer: glm-api → deepseek-dsh (glm-api: quota).` Переходы между встроенными профилями объявляются прежними строками, например `GLM channel failed … falls back to Luna max`.
- **Kill switch.**
  - «без GLM» и «через Luna» работают как раньше.
  - «без <профиль>» исключает любой профиль из всех цепочек до конца сессии. В примере выше «без GLM» отправит все фазы, включая рисковые, на `deepseek-dsh`.
  - `SP_IMPLEMENTER=luna` работает как раньше. `SP_IMPLEMENTER=<профиль>` с профилем, который вы сами задали в `config.json` и который работает вне сессии, делает его имплементером для всех фаз, кроме фронтенда, и выключает GLM; если он упадёт, пайплайн спросит вас, а не перейдёт к другому профилю. `SP_IMPLEMENTER=glm` называет профиль по умолчанию и ничего не меняет. Любое другое значение, как и раньше, игнорируется: встроенное имя вроде `sol` (чтобы имплементером стал Sol, напишите в `config.json` `"implementer": ["sol"]`), неизвестное имя, профиль для сессии. GLM остаётся включённым. Если своих профилей у вас нет, пайплайн ничего не сообщает, а если есть — при старте выводит одну строку-предупреждение.
- **Правило семейств.** Во встроенной схеме автор и ревьюер артефакта принадлежат разным модельным семействам. `agent-dispatch` вашу маршрутизацию на это не проверяет. Ревьюер должен быть из другого семейства моделей, чем автор плана и имплементер.

### Что разрешают провайдеры — для справки, по состоянию на 2026-10-20; ответственность ваша

| Подписка / ключ | Разрешено официально | Серая зона | Не разрешено |
|---|---|---|---|
| Claude Pro/Max | Claude Code, включая `claude -p` [AN1, AN4] | — | OAuth в сторонних харнессах (OpenCode, pi и др.) |
| ChatGPT Plus/Pro | Codex; OpenCode, pi («Sign in with ChatGPT»), Kilo [OA1, OA6] | харнессы, которых OpenAI не называет | ChatGPT Business/Enterprise в сторонних харнессах |
| GLM Coding Plan | ZCode, Claude Code, Codex, OpenCode, pi, Crush, Kilo, Cline | — | инструменты, которых нет в списке Z.ai (Qwen Code, Kimi CLI, dsh) |
| GitHub Copilot | OpenCode [GH1] | Crush, Kilo, Cline | вход pi (pi представляется VS Code) |
| OpenCode Go | Claude Code, Codex, ZCode, pi, OpenCode, Kilo | — | — |
| OpenCode Zen | OpenCode | вне OpenCode | — |
| Kimi Code | интерактивная работа | неинтерактивный (headless) запуск (правила Kimi: «только интерактивно», хотя документация CLI показывает `kimi -p`) | — |
| MiniMax M Plan | любой совместимый инструмент | неинтерактивный (headless) запуск (подписка задумана для интерактивной работы) | — |
| Alibaba Coding Plan | интерактивная работа | — | неинтерактивный (headless) запуск [AL1] |
| Alibaba / QwenCloud Token Plan | — | неинтерактивный (headless) запуск | — |
| Google AI (Gemini, Antigravity) | инструменты Google | — | OAuth в сторонних харнессах; запуск `agy` из стороннего харнесса |
| Ollama Cloud | — | автоматизация (в условиях явно не разрешена) | — |
| Любой PAYG-ключ (DeepSeek, Z.ai Standard, Kimi Platform, MiniMax API, Alibaba PAYG, OpenRouter) | любой харнесс | — | — |
| Локальная модель | любой харнесс | — | — |

`claude -p` со сторонним эндпоинтом не нарушает условия Anthropic, но Anthropic такую конфигурацию не поддерживает.

ID источников в квадратных скобках ведут в [docs/research/universal-dispatchers/07-tos-matrix.md](./docs/research/universal-dispatchers/07-tos-matrix.md).

### Если что-то сломалось

Соберите три вещи и приложите их к issue или к сообщению владельцу:

- вывод `agent-dispatch doctor --profile <p>`;
- вывод `agent-dispatch status <id> --json`;
- лог задачи — `state/<workspace>/jobs/<id>.log` в каталоге данных выше. Секреты в нём вычищены.

Если эндпоинт отвергает beta-поля запроса, добавьте в `env` профиля `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`.

## Защитные механизмы

- **Ручной запуск** — у pipeline-скиллов стоит `disable-model-invocation: true`: модель не видит их описания и не загружает их самостоятельно. Пайплайн запускается только по вашей команде, скиллы переходят друг к другу через чтение файлов `SKILL.md`, а незавершённый план возобновляется только по вашей просьбе. Discipline-скиллы (`systematic-debugging`, `test-driven-development`, `verification-before-completion`, `receiving-code-review`) по-прежнему включаются автоматически.
- **Независимое суждение** — автор и ревьюер артефакта принадлежат разным модельным семействам.
- **Authorization ledger** — замечания проходят триаж до передачи фиксеру; расширение scope не реализуется молча.
- **Ограниченные циклы** — ревью плана и фазы ограничено четырьмя раундами, финальное ревью ветки — двумя.
- **Без review ping-pong** — отклонённые замечания не возвращаются без нового основания, одинаковые списки блокеров эскалируются, а поздний малозначимый churn не может бесконечно удерживать цикл.
- **Власть человека** — конфликты с планом, материальное расширение scope и неразрешимые тупики возвращаются пользователю.
- **Безопасный Git** — без `--no-verify`, amend, force push и push без явного согласия в текущей сессии.
- **Изолированный параллелизм** — независимые фазы из плана могут идти в отдельных worktree с жёстким лимитом параллелизма два.
- **Доступ к GLM по правилам Z.ai** — GLM вызывается только через собственный ZCode CLI от Z.ai с честной идентификацией клиента; без прямого API и извлечения токенов; GLM никогда не получает фазы SECURITY / DATA_LOSS и работает без песочницы только внутри git-дерева под ограничениями преамбулы.

## Что входит в плагин

### Собственные возможности форка

| Компонент | Назначение |
|---|---|
| `dev-orchestrator` | Полный протокол планирования, реализации, верификации, ревью, коммитов и возобновления |
| `codex-invocation` | Надёжный фоновый dispatch Codex через вендорный companion runtime |
| `zcode-invocation` | Фоновый dispatch GLM-5.3-Flash через ZCode CLI от Z.ai: настройка, doctor/probe, цикл Monitor, обработка сбоев |
| `agent-invocation` | Маршрутизация ролей через профили `agent-dispatch`: `route`, задачи по префиксу id, классы сбоев, headless-преамбулы |
| `architecture-memory` | Компактная персистентная карта архитектуры в `docs/ARCHI.md` |
| `/dev` | Явная точка входа в полный протокол; без задачи — продолжение незавершённого плана |
| `bin/pipeline-context` | SessionStart-хук: называет незавершённый план и скилл, который нужно перечитать после компакции; в остальных случаях молчит |
| `bin/review-package` | Генерирует готовые для ревьюера пакеты коммитов и diff |
| `bin/sdd-workspace` | Резолвит изолированные scratch-workspace для каждого плана |
| `bin/zcode-dispatch` | Обёртка задач ZCode CLI: task/status/result/cancel/release-stale/doctor/api-key с закреплёнными моделью, режимом и идентификацией клиента; `release-stale` освобождает резервацию рабочего дерева, оставленную упавшей задачей, после проверки, что та мертва |
| `bin/agent-dispatch` | Профили, ключи и маршруты ролей (`route`, `channels`, `doctor`); один `status` по задачам ZCode, Codex и своим; сквозной вызов `zcode-dispatch` и `codex-dispatch` |

### Адаптированные скиллы Superpowers

`brainstorming`, `dispatching-parallel-agents`, `executing-plans`, `finishing-a-development-branch`, `receiving-code-review`, `requesting-code-review`, `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `verification-before-completion`, `writing-plans` и `writing-skills`.

Upstream-скилл `subagent-driven-development` заменён на `dev-orchestrator`. Агрессивная инъекция `using-superpowers` и её SessionStart-хук намеренно не включены; собственный SessionStart-хук плагина подаёт голос только при незавершённом плане или когда после компакции нужно перечитать скилл пайплайна.

<details>
<summary><strong>Карта репозитория</strong></summary>

```text
.
├── .claude-plugin/plugin.json       # Манифест и версия исходников
├── commands/dev.md                  # Точка входа команды /dev
├── hooks/hooks.json                 # SessionStart → bin/pipeline-context
├── bin/
│   ├── agent-dispatch               # Профили, ключи, маршруты ролей, отправка задач
│   ├── codex-dispatch               # Обёртка вендорного companion
│   ├── pipeline-context             # Незавершённый план / подсказка перечитать скилл
│   ├── review-package               # Генератор diff-пакета для ревьюеров
│   ├── sdd-workspace                # Резолвер scratch-workspace для плана
│   ├── zcode-dispatch               # Обёртка задач ZCode CLI (shim)
│   ├── lib/zcode-dispatch.mjs       # Раннер задач ZCode, записи, doctor
│   ├── lib/agent-core.mjs           # Общее ядро задач agent-dispatch
│   ├── lib/agent-dispatch.mjs       # CLI agent-dispatch, конфигурация, маршруты
│   ├── lib/agents-defaults.json     # Встроенные профили, роли, пресеты
│   └── lib/adapters/                # Адаптеры харнессов
├── skills/
│   ├── dev-orchestrator/            # Протокол и шаблоны промптов ролей
│   ├── agent-invocation/
│   ├── codex-invocation/
│   ├── zcode-invocation/
│   ├── architecture-memory/
│   └── ...                          # Адаптированные скиллы Superpowers
├── tests/test-sdd-scripts.sh        # Интеграционные тесты workspace/package
├── tests/test-pipeline-context.sh   # SessionStart-хук и проверки manual-only скиллов
├── tests/test-zcode-dispatch.sh     # Тесты обёртки ZCode (CLI-заглушка)
├── tests/test-agent-core.sh         # Тесты ядра задач (тривиальный адаптер)
├── tests/test-agent-dispatch.sh     # Тесты agent-dispatch (заглушки обёрток)
├── tests/test-orchestrator-defaults.sh  # Встроенные роли, команды и лимиты не изменились
└── vendor/codex-companion/          # Вендорный companion runtime OpenAI
```

</details>

<details>
<summary><strong>Вендорный Codex companion</strong></summary>

Все вызовы Codex идут через `bin/codex-dispatch`. Обёртка работает из marketplace-установки или локального checkout и изолирует состояние в `~/.claude/plugins/data/superpowers-strigov-ver-codex`.

Upstream-база записана в `vendor/codex-companion/VERSION`. Локальные патчи добавляют адресный resume, reasoning-efforts `max`/`ultra` для GPT-6, очистку broker-процессов и необязательные поля авторизации ревью.

</details>

## Разработка и выпуски

Запуск тестовых suite:

```bash
bash tests/test-sdd-scripts.sh
bash tests/test-pipeline-context.sh
bash tests/test-zcode-dispatch.sh
bash tests/test-agent-core.sh
bash tests/test-agent-dispatch.sh
bash tests/test-orchestrator-defaults.sh
```

Для выпуска синхронизируйте версию в `.claude-plugin/plugin.json`, обоих README, `PLUGIN_README.md` и записи плагина во внешнем [каталоге marketplace `strigov-cc-plugins`](https://github.com/strigov/strigov-cc-plugins). Обновление только этого репозитория не публикует новую marketplace-версию.

## Происхождение

- [Superpowers](https://github.com/obra/superpowers) от Jesse Vincent / obra — MIT. Форк включает адаптированные скиллы v5.0.7 и отдельные, проверенные по исходникам механизмы Superpowers 6 v6.1.1.
- [TRIP-workflow](https://github.com/PiLastDigit/TRIP-workflow) от PiLastDigit — MIT. Отсюда адаптированы адресный resume, verification gate, синтез ревью, шаблон разовой консультации и концепция architecture memory.
- Вендорный Codex companion происходит из `codex-plugin-cc` OpenAI и сохраняет лицензию Apache-2.0.

## Лицензия

Оригинальная часть репозитория опубликована по [лицензии MIT](./LICENSE). Вендорные компоненты сохраняют свои лицензии.
