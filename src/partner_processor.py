import logging
import boto3
import pandas as pd
import uuid

from datetime import datetime
from typing import Dict

logger = logging.getLogger()
logger.setLevel(logging.DEBUG)

class DataProcessor:
    
    def __init__(self):
        logger.debug('Init method called')
        # Define the objects here using boto
        self.dynamo_table = boto3.resource('dynamodb')
        self.s3_client = boto3.client('s3')
        self.sqs_client = boto3.client('sqs')
        self.files_names: Dict[str, str] = None
        self.customers_df = None
        self.orders_df = None
        self.items_df = None

    def get_file_names(self):
        # Function to fetch the name of the files by appending the YYYYMMDD extention
        logger.debug('get_file_names method called')
        extension: str = datetime.today().strftime('%Y%m%d')
        for file_name in ['customers', 'orders', 'items']:
            self.files_names[file_name] = f'{file_name}_{extension}.csv'
        logger.info(f'File names dict: {self.files_names}')

    def csv_to_df(self, bucket_name: str):
        # Function to load the csv into the respective dfs, uses the bucket name as an argument
        bucket_prefix: str = f's3://{bucket_name}'
        self.customers_df = pd.read_csv(f'{bucket_prefix}/{self.files_names['customers']}')
        self.orders_df = pd.read_csv(f'{bucket_prefix}/{self.files_names['orders']}')
        self.items_df = pd.read_csv(f'{bucket_prefix}/{self.files_names['items']}')
        logger.info('loaded all dataframes')

    def generate_json_output(self):
        # Business logic to generate json goes here json_valid_output and json_error_output generated here
        # Logic is to filter out all records that have a valid order_reference and customer_reference and later perform an aggrgation on top of that
        orders_missing_customer_reference_df = orders_df[~orders_df['customer_reference'].isin(customers_df['customer_reference'].tolist())][['order_reference']]
        # Add uuid for keying purposes
        orders_missing_customer_reference_df['uuid'] = [uuid.uuid4() for _ in range(len(orders_missing_customer_reference_df.index))]
        orders_missing_customer_reference_df['type'] = 'error_message'
        orders_missing_customer_reference_df['customer_reference'] =  None
        orders_missing_customer_reference_df['message'] =  'Something went wrong!'
        items_missing_orders_reference_df = items_df[~items_df['order_reference'].isin(orders_df['order_reference'].tolist())][['order_reference']]
        items_missing_orders_reference_df['uuid'] = [uuid.uuid4() for _ in range(len(items_missing_orders_reference_df.index))]
        items_missing_orders_reference_df['type'] = 'error_message'
        items_missing_orders_reference_df['message'] =  'Something went wrong!'
        valid_orders_df = orders_df[orders_df['customer_reference'].isin(customers_df['customer_reference'].tolist())]
        valid_items_df = items_df[items_df['order_reference'].isin(orders_df['order_reference'].tolist())]
        valid_df_inner = pd.merge(valid_orders_df, valid_items_df, on='order_reference', how='inner')
        result_df = valid_df_inner.groupby('customer_reference').agg({'order_reference': 'nunique', 'total_price': 'sum'}).rename(columns={'total_price': 'total_amount_spent', 'order_reference': 'number_of_orders'}).reset_index()
        result_df['type'] = 'customer_message'
        result_df['uuid'] = [uuid.uuid4() for _ in range(len(result_df.index))]
        self.json_valid_output = result_df.to_dict('records')
        self.json_error_output = orders_missing_customer_reference_df.to_dict('records') + items_missing_orders_reference_df.to_dict('records')
        logger.info('Computation completed')


    def write_to_sqs(self):
        # Logic to write data to sqs queue
        logger.info(f"Writing to SQS")
        queue_url = self.sqs_client.get_queue_url(QueueName='partner_sqs_queue')
        self.sqs_client.send_message(QueueUrl=queue_url, MessageBody=self.json_valid_output)
        self.sqs_client.send_message(QueueUrl=queue_url, MessageBody=self.json_error_output)

    def write_to_dynamodb(self):
        # Logic to store data to dynamo db
        logger.info(f"Writing to DynamoDB")
        table = self.dynamo_table.Table('partner_table')
        table.put_item(Item = self.json_valid_output)
        table.put_item(Item = self.json_error_output)

def lambda_handler(event, context):
    logger.info(f"event: {event}")
    logger.info(f"context: {context}")
    
    bucket = event["Records"][0]["s3"]["bucket"]["name"]
    data_processor = DataProcessor() 
    data_processor.get_file_names()

    # Now check if all the three files have been uploaded for the day
    customers = data_processor.s3_client.list_objects(Bucket=bucket, Prefix=data_processor.files_names['customers'])
    orders = data_processor.s3_client.list_objects(Bucket=bucket, Prefix=data_processor.files_names['orders'])
    items = data_processor.s3_client.list_objects(Bucket=bucket, Prefix=data_processor.files_names['items'])

    if 'Contents' in customers and 'Contents' in orders and 'Contents' in items:
        # This means all 3 files have arrived
        data_processor.csv_to_df(bucket)
        data_processor.generate_json_output()
        data_processor.write_to_sqs()
        data_processor.write_to_dynamodb()
