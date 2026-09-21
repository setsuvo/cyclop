# Подпись и нотаризация

Релиз подписывается сертификатом Developer ID и нотаризуется у Apple. Тогда
приложение открывается с первого раза, без «Открыть всё равно», а подменённый
файл внутри бандла не запускается вовсе (#20). Делает это раннер в
`release.yml`; ему нужны пять секретов защищённого GitHub Environment
`release`. Как их получить и настроить границу доступа — ниже, один раз.

Локальная сборка (`Scripts/bundle.sh`) остаётся ad-hoc и ничего из этого не
требует.

## 0. Защитить путь к секретам

Apple-секреты нельзя хранить как обычные repository secrets: любой изменённый
workflow в репозитории смог бы сослаться на них. В **Settings → Environments**
создать environment с точным именем **`release`** и настроить:

- хотя бы одного **Required reviewer**, который не является человеком,
  поставившим тег; включить запрет самостоятельного одобрения;
- **Deployment branches and tags → Selected branches and tags**: разрешить
  только теги `v*`, не ветки;
- пять секретов из таблицы ниже — именно как **environment secrets**.

В **Settings → Rules → Rulesets** нужны ещё два правила:

1. Default branch: изменения только через review, без прямого обхода, и
   обязательный успешный check workflow `build`.
2. Теги `v*`: запретить создание посторонним, а также обновление и удаление
   уже поставленных тегов; право создания оставить только выпускающим.

Одинаковые Apple-секреты уровня repository или organization следует удалить:
иначе другой job, не привязанный к environment, всё ещё сможет обратиться к
менее строго защищённой копии. Перед одобрением environment reviewer проверяет
SHA/тег в `validate_release` и изменения `.github/workflows/release.yml` с
прошлого релиза.

Граница в workflow устроена так:

- `validate_release` допускает только тег на истории default branch, чей
  точный SHA уже успешно прошёл push-run `build.yml`;
- `build_candidate` checkout'ит этот SHA и запускает скрипт сборки **без**
  Apple-секретов;
- только `sign_release` получает environment secrets; он не делает checkout и
  не исполняет файлы из артефакта. Его доверенная база ограничена закреплёнными
  по SHA artifact actions, проверенными inline-командами workflow и системными
  `codesign`, `notarytool`, `stapler` и `hdiutil`;
- ручной `workflow_dispatch` — всегда неподписанный dry run и к environment
  `release` не подключается.

Из-за этой проверки тег ставится лишь после зелёного `build` на том же коммите.
Тег, созданный раньше CI или вне default branch, ожидаемо завершит workflow с
ошибкой до этапа подписи.

Минимальный список entitlements намеренно продублирован внутри доверенного
шага `sign_release`: подписывающий job не принимает права из недоверенного
артефакта. При изменении `Resources/Cyclop.entitlements` тот же reviewed PR
должен синхронно обновить список в `release.yml`.

## 1. Сертификат Developer ID Application

Xcode не нужен, хватает Command Line Tools и Связки ключей.

1. **Запрос сертификата.** Связка ключей → меню Связка ключей → Ассистент
   сертификации → Запросить сертификат у бюро сертификации. Почта аккаунта
   разработчика, имя любое, «Сохранён на диск». Закрытый ключ при этом ложится
   в связку ключей login — он и есть половина сертификата, экспортировать
   потом придётся именно из этой связки.
2. **Выпуск.** [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
   → «+» → **Developer ID Application** (не Installer, не Mac App
   Distribution) → загрузить запрос → скачать `.cer` → двойной клик, чтобы он
   лёг в login.
3. **Проверка.**
   ```sh
   security find-identity -v -p codesigning
   ```
   Должна быть строка `"Developer ID Application: Имя (TEAMID)"`. Если
   сертификат виден, но помечен как невалидный, не хватает промежуточного
   сертификата Apple: скачать **Developer ID - G2** с
   [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
   и тоже открыть двойным кликом.

## 2. Экспорт для раннера

Связка ключей → Мои сертификаты → правой кнопкой по «Developer ID
Application: …» → Экспортировать → формат `.p12`, придумать пароль. Файл
содержит и сертификат, и закрытый ключ: после загрузки в секреты удалить.

```sh
base64 -i DeveloperID.p12 | gh secret set --env release DEVELOPER_ID_P12
gh secret set --env release DEVELOPER_ID_P12_PASSWORD  # спросит пароль от .p12
```

## 3. Ключ нотаризации

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Пользователи
и доступ → Интеграции → App Store Connect API → Team Keys → «+». Имя любое,
роль **Developer** — большего нотаризации не нужно. Записать **Key ID** и
**Issuer ID** (сверху страницы), скачать `.p8` — Apple отдаёт его **один
раз**, второй раз не скачать.

```sh
gh secret set --env release NOTARY_KEY_ID                  # Key ID
gh secret set --env release NOTARY_ISSUER_ID               # Issuer ID
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set --env release NOTARY_KEY_P8
```

## 4. Проверить локально до первого релиза

Один раз положить ключ в связку ключей под именем профиля, чтобы не держать
его в окружении:

```sh
xcrun notarytool store-credentials cyclop \
    --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer 00000000-0000-0000-0000-000000000000
```

Потом собрать релизный образ так же, как это сделает раннер:

```sh
CODESIGN_IDENTITY="Developer ID Application: Имя (TEAMID)" \
NOTARIZE=1 NOTARY_PROFILE=cyclop \
./Scripts/dmg.sh
```

Скрипт нотаризует приложение, потом образ, скрепляет билеты к обоим и в
конце сам спрашивает Gatekeeper. Если он дошёл до «готово», образ откроется
на любом Mac с первого раза. Проверить всё равно стоит на машине, где Cyclop
ещё не запускали: разница между «у меня работает» и «у него открылось» — и
есть суть проверки (#20).

## Что где лежит

| Секрет | Что это |
|---|---|
| `DEVELOPER_ID_P12` | сертификат с ключом, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | пароль от него |
| `NOTARY_KEY_ID` | Key ID ключа App Store Connect |
| `NOTARY_ISSUER_ID` | Issuer ID команды |
| `NOTARY_KEY_P8` | сам ключ `.p8`, base64 |

Все пять обязательны для тегового релиза. Без них `sign_release` завершится с
ошибкой после одобрения environment; автоматического понижения до ad-hoc для
релиза нет. Пробный прогон (ручной запуск `release.yml`) всегда ad-hoc и не
получает ни один из этих секретов.

Сертификат Developer ID действует пять лет, ключ App Store Connect не
истекает, пока его не отозвать. Оба можно отозвать на тех же страницах, где
выпускали, — это единственное, что надо сделать, если секреты утекли.
