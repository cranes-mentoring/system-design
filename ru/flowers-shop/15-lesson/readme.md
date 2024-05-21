### Урок: Написание Python Background Service для чтения из Kafka

#### Введение

В этом уроке мы научимся писать фоновый сервис на Python, который будет слушать сообщения из Apache Kafka.
Мы рассмотрим различные методы чтения сообщений из Kafka, а также разные варианты подтверждения о том, что сообщения были успешно прочитаны.

#### 1. Установка зависимостей

Первым шагом является установка необходимых библиотек, таких как `kafka-python`, которая позволит вам работать с Kafka в Python.

```bash
pip install kafka-python
```

#### 2. Настройка подключения к Kafka

Для начала нужно определить параметры подключения к брокеру Kafka.

```python
from kafka import KafkaConsumer

# Настройки для подключения к Kafka
bootstrap_servers = 'localhost:9092'
topic = 'my_topic'
group_id = 'my_group_id'
```

#### 3. Создание консьюмера Kafka

Создадим экземпляр консьюмера Kafka с указанными параметрами.

```python
consumer = KafkaConsumer(topic,
                         group_id=group_id,
                         bootstrap_servers=bootstrap_servers,
                         auto_offset_reset='earliest')
```

#### 4. Чтение сообщений из Kafka

Теперь мы можем начать чтение сообщений из Kafka. Мы также рассмотрим вариант чтения пачками, а не по одному сообщению.

```python
# Чтение сообщений по одному
for message in consumer:
    print(f"Received message: {message.value.decode('utf-8')}")

# Чтение сообщений пачками
for batch in consumer:
    for message in batch:
        print(f"Received message: {message.value.decode('utf-8')}")
```

#### 5. Подтверждение успешного чтения сообщений

Существует несколько способов подтверждения успешного чтения сообщений из Kafka. Рассмотрим некоторые из них.

##### Автоматическое подтверждение (auto.commit.enable=True)

В этом режиме библиотека автоматически подтверждает оффсет после успешного чтения сообщения. Это наиболее простой, но не всегда самый надежный способ.

```python
consumer = KafkaConsumer(topic,
                         group_id=group_id,
                         bootstrap_servers=bootstrap_servers,
                         auto_offset_reset='earliest',
                         enable_auto_commit=True)
```

##### Ручное подтверждение (auto.commit.enable=False)

В этом режиме приложение самостоятельно контролирует подтверждение оффсета после успешного обработки сообщения. Это более надежный способ, но требует дополнительной логики.

```python
consumer = KafkaConsumer(topic,
                         group_id=group_id,
                         bootstrap_servers=bootstrap_servers,
                         auto_offset_reset='earliest',
                         enable_auto_commit=False)
```

После успешной обработки сообщения необходимо явно подтвердить оффсет.

```python
for message in consumer:
    process_message(message)
    consumer.commit()
```

#### Заключение

Этот урок предоставил вам основы написания фонового сервиса на Python для чтения сообщений из Apache Kafka. Вы также изучили различные варианты чтения сообщений и методы подтверждения успешного чтения. Это только начало вашего пути к созданию мощных и надежных систем, использующих Apache Kafka для обмена сообщениями.