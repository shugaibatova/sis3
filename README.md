

Весь проект поднимается **одной командой** и **без единого клика в консоли AWS**.

```bash
bash deploy.sh sis3-main
```

## Что здесь есть

| Файл | Что это | Зачем |
|---|---|---|
| `template.yaml` | Шаблон CloudFormation | Описывает ВСЮ инфраструктуру: очереди, SNS, DynamoDB, ECR, ALB, ECS, роли, логи |
| `app.py` | Приложение на Python | HTTP (`/health`, `/publish`) + consumer, который читает очередь SQS |
| `Dockerfile` | Описание образа | Упаковывает `app.py` в контейнер |
| `deploy.sh` | Скрипт деплоя | Единственная команда: создать стек, собрать и загрузить образ, запустить сервис |
| `demo.sh` | Скрипт демо | Показывает дедупликацию и DLQ для защиты |

## Что покрывает задание

**Неделя 9, Messaging** (в `template.yaml`, блок «MESSAGING»)
- `OrdersQueue` с `RedrivePolicy` (`maxReceiveCount` = параметр, по умолчанию 3) и `DeadLetterQueue`
- Доменное событие `OrderCreated` идёт через SNS-топик `OrderEventsTopic`, очередь подписана на него
- Идемпотентный consumer (`app.py`, функция `handle`): ключ дедупликации `eventId` пишется в DynamoDB условной записью; дубль пропускается, в логах видно `dedup_key=...`

**Неделя 10, Container** (блок «CONTAINER»)
- ECR: `ImageTagMutability: IMMUTABLE` + `LifecyclePolicy` (хранить 10 последних образов)
- ECS Fargate за ALB (`Cluster`, `TaskDefinition`, `Service`, `LoadBalancer`, `Listener`, `TargetGroup`)
- Две отдельные роли: `TaskExecutionRole` (для ECS: тянуть образ, писать логи) и `TaskRole` (для кода приложения: только нужные SQS/DynamoDB/SNS)
- Логи в CloudWatch: `LogGroup` с `RetentionInDays` (параметр `LogRetentionDays`)

**Неделя 11, As code**
- Всё выше в CloudFormation, лежит в git
- Параметры окружения: `Environment`, `ImageTag`, `DesiredCount`, `MaxReceiveCount`, `LogRetentionDays`, `VpcId`, `SubnetIds`
- Секретов нет ни в шаблоне, ни в коде (доступ даётся IAM-ролью)
- Одна команда деплоя: `bash deploy.sh <имя-стека>`

---

## Часть 1. Подготовка компьютера (один раз)

1. **Аккаунт AWS** с правами на CloudFormation, IAM, ECR, ECS, EC2/ELB, SQS, SNS, DynamoDB, Logs. В учебном аккаунте обычно это AdministratorAccess.
2. **AWS CLI v2**: https://aws.amazon.com/cli/ . Проверка: `aws --version`
3. **Docker** (Docker Desktop должен быть запущен). Проверка: `docker version`
4. **Git** и **bash**. На Windows используйте Git Bash или WSL, а не PowerShell.
5. **Ключи доступа**: в консоли AWS откройте IAM, свой пользователь, Security credentials, Create access key. Затем в терминале:
   ```bash
   aws configure
   ```
   Введите Access Key ID, Secret Access Key, регион (например `eu-central-1`), формат `json`.
   Проверка: `aws sts get-caller-identity` должен показать ваш аккаунт.
   Ключи никому не показывайте и не кладите в git.
6. Регион: по умолчанию скрипты используют `eu-central-1`. Другой регион: `export AWS_REGION=us-east-1`.

## Часть 2. Деплой

```bash
git clone https://github.com/shugaibatova/sis3 sis3
cd sis3
bash deploy.sh sis3-main
```

Что делает скрипт:
1. Создаёт стек с `DesiredCount=0`: инфраструктура готова, но задач нет, потому что образа в ECR ещё нет.
2. Собирает Docker-образ, логинится в ECR и пушит его с тегом из `git rev-parse --short HEAD`.
3. Обновляет стек с `DesiredCount=1`: Fargate запускает контейнер.
4. Ждёт готовности и печатает адрес приложения.

Занимает 5-10 минут. Проверка:

```bash
curl http://<адрес-ALB>/health      # {"status": "ok"}
```

Если сразу после деплоя ALB отвечает 503, подождите 1-2 минуты, пока health-check пройдёт.

## Часть 3. Демо (то, что показывать на защите)

```bash
bash demo.sh sis3-main
```

Скрипт покажет:
1. **Идемпотентность**: событие с одним `eventId` отправляется дважды. В логах первое `PROCESSED dedup_key=...`, второе `DUPLICATE skipped dedup_key=...`.
2. **DLQ**: «ядовитое» сообщение падает 3 раза (`ERROR attempt=1,2,3`), затем попадает в DLQ, и счётчик сообщений в DLQ становится 1.

Смотреть логи вручную:
```bash
aws logs tail <LogGroupName из Outputs> --follow
```

## Часть 4. Тест воспроизводимости (то, что проверит преподаватель)

Со **свежего checkout** поднимаем вторую копию под другим именем стека:

```bash
git clone https://github.com/shugaibatova/sis3 sis3-clean
cd sis3-clean
bash deploy.sh sis3-copy
bash demo.sh sis3-copy
```

Два стека живут рядом и не конфликтуют, потому что в шаблоне нет жёстко заданных имён ресурсов.

## Часть 5. Удаление (чтобы не платить за ALB и Fargate)

```bash
aws cloudformation delete-stack --stack-name sis3-copy
aws cloudformation wait stack-delete-complete --stack-name sis3-copy
```

---

## Если что-то пошло не так

| Ошибка | Что делать |
|---|---|
| `Unable to locate credentials` | Выполните `aws configure` |
| `Cannot connect to the Docker daemon` | Запустите Docker Desktop |
| Стек в статусе `ROLLBACK_COMPLETE` | `deploy.sh` удалит его сам; причину смотрите в CloudFormation, вкладка Events |
| `already exists` | В шаблон попало жёстко заданное имя ресурса; уберите его |
| Задачи ECS не стартуют | ECS, кластер, сервис, вкладка Events; чаще всего нет образа с нужным тегом в ECR |
| Образ собран на Mac M1/M2, задача падает | Скрипт уже собирает с `--platform linux/amd64` |
| `tag invalid: The image tag ... already exists` | Теги неизменяемые; скрипт пропускает повторный push, при ручной сборке сделайте новый коммит |
| 503 от ALB | Подождите 1-2 минуты, пока цель станет healthy |

## Как отвечать на вопросы на защите

- **Почему два прохода деплоя?** Сервису нужен образ в ECR, а репозиторий создаётся самим стеком. Сначала создаём репозиторий (задач 0), потом пушим образ, потом запускаем задачи.
- **Почему две роли?** Execution role нужна платформе ECS (образ и логи), task role нужна коду (SQS, DynamoDB, SNS). Права приложения отделены от прав платформы, и у каждой роли минимум прав.
- **Зачем DLQ и maxReceiveCount?** Сообщение, которое не удаётся обработать, не должно крутиться вечно: после 3 попыток оно уходит в DLQ, где его можно разобрать вручную.
- **Почему нужна идемпотентность?** SQS Standard доставляет сообщения «минимум один раз», поэтому дубли возможны. Условная запись в DynamoDB по `eventId` гарантирует, что событие будет обработано один раз.
- **Зачем immutable-теги?** Тег всегда указывает на один и тот же образ, и можно точно сказать, какой код работает (тег = git commit).
- **Почему нет секретов?** Приложение получает доступ через IAM-роль задачи, а параметры не содержат паролей.
