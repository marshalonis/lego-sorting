from aws_cdk import (
    Stack,
    Duration,
    RemovalPolicy,
    CfnOutput,
    aws_dynamodb as dynamodb,
    aws_s3 as s3,
    aws_s3_deployment as s3_deploy,
    aws_lambda as lambda_,
    aws_apigatewayv2 as apigwv2,
    aws_apigatewayv2_integrations as integrations,
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_iam as iam,
)
from constructs import Construct
import os


class LegoSortingStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        # ── DynamoDB Tables ──────────────────────────────────────────────────

        drawers_table = dynamodb.Table(
            self, "DrawersTable",
            table_name="lego-drawers",
            partition_key=dynamodb.Attribute(name="id", type=dynamodb.AttributeType.STRING),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            removal_policy=RemovalPolicy.RETAIN,
        )
        # GSI to look up drawer by cabinet/row/col
        drawers_table.add_global_secondary_index(
            index_name="location-index",
            partition_key=dynamodb.Attribute(name="location_key", type=dynamodb.AttributeType.STRING),
        )

        parts_table = dynamodb.Table(
            self, "PartsTable",
            table_name="lego-parts",
            partition_key=dynamodb.Attribute(name="part_num", type=dynamodb.AttributeType.STRING),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            removal_policy=RemovalPolicy.RETAIN,
        )
        # GSI to list all parts in a drawer
        parts_table.add_global_secondary_index(
            index_name="drawer-index",
            partition_key=dynamodb.Attribute(name="drawer_id", type=dynamodb.AttributeType.STRING),
        )

        # ── S3 Buckets ───────────────────────────────────────────────────────

        # UI bucket — private, served via CloudFront only
        ui_bucket = s3.Bucket(
            self, "UIBucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
            cors=[s3.CorsRule(
                allowed_methods=[s3.HttpMethods.GET],
                allowed_origins=["*"],
            )],
        )

        # Images bucket — brick photos uploaded directly from browser
        images_bucket = s3.Bucket(
            self, "ImagesBucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
            lifecycle_rules=[
                s3.LifecycleRule(expiration=Duration.days(1))  # auto-delete after 1 day
            ],
            cors=[s3.CorsRule(
                allowed_methods=[s3.HttpMethods.PUT, s3.HttpMethods.GET],
                allowed_origins=["*"],
                allowed_headers=["*"],
            )],
        )

        # Catalog bucket — Rebrickable parts CSV
        catalog_bucket = s3.Bucket(
            self, "CatalogBucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=RemovalPolicy.RETAIN,
        )

        # ── Lambda ───────────────────────────────────────────────────────────

        lambda_role = iam.Role(
            self, "LambdaRole",
            assumed_by=iam.ServicePrincipal("lambda.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaBasicExecutionRole"),
            ],
        )

        # Bedrock access
        lambda_role.add_to_policy(iam.PolicyStatement(
            actions=["bedrock:InvokeModel", "bedrock:ListInferenceProfiles"],
            resources=["*"],
        ))

        drawers_table.grant_read_write_data(lambda_role)
        parts_table.grant_read_write_data(lambda_role)
        images_bucket.grant_read_write(lambda_role)
        catalog_bucket.grant_read_write(lambda_role)

        api_lambda = lambda_.Function(
            self, "ApiLambda",
            runtime=lambda_.Runtime.PYTHON_3_12,
            code=lambda_.Code.from_asset(
                os.path.join(os.path.dirname(__file__), "../../lambda/api"),
                bundling=lambda_.BundlingOptions(
                    image=lambda_.Runtime.PYTHON_3_12.bundling_image,
                    command=[
                        "bash", "-c",
                        "pip install -r requirements.txt -t /asset-output && cp -r . /asset-output",
                    ],
                ),
            ),
            handler="handler.handler",
            role=lambda_role,
            timeout=Duration.seconds(60),
            memory_size=512,
            environment={
                "DRAWERS_TABLE": drawers_table.table_name,
                "PARTS_TABLE": parts_table.table_name,
                "IMAGES_BUCKET": images_bucket.bucket_name,
                "CATALOG_BUCKET": catalog_bucket.bucket_name,
                "AWS_ACCOUNT_REGION": self.region,
            },
        )

        # Catalog loader — separate Lambda for one-time Rebrickable download
        catalog_loader_lambda = lambda_.Function(
            self, "CatalogLoaderLambda",
            runtime=lambda_.Runtime.PYTHON_3_12,
            code=lambda_.Code.from_asset(
                os.path.join(os.path.dirname(__file__), "../../lambda/catalog_loader"),
                bundling=lambda_.BundlingOptions(
                    image=lambda_.Runtime.PYTHON_3_12.bundling_image,
                    command=[
                        "bash", "-c",
                        "pip install -r requirements.txt -t /asset-output && cp -r . /asset-output",
                    ],
                ),
            ),
            handler="handler.handler",
            role=lambda_role,
            timeout=Duration.seconds(300),
            memory_size=512,
            environment={
                "CATALOG_BUCKET": catalog_bucket.bucket_name,
            },
        )

        # ── API Gateway (HTTP API) ────────────────────────────────────────────

        http_api = apigwv2.HttpApi(
            self, "HttpApi",
            api_name="lego-sorting-api",
            cors_preflight=apigwv2.CorsPreflightOptions(
                allow_origins=["*"],
                allow_methods=[apigwv2.CorsHttpMethod.ANY],
                allow_headers=["*"],
            ),
        )

        lambda_integration = integrations.HttpLambdaIntegration(
            "ApiIntegration", api_lambda,
        )

        http_api.add_routes(
            path="/{proxy+}",
            methods=[apigwv2.HttpMethod.ANY],
            integration=lambda_integration,
        )

        # ── CloudFront ────────────────────────────────────────────────────────

        # OAC for S3 UI bucket
        oac = cloudfront.S3OriginAccessControl(self, "OAC")

        # API Gateway origin
        api_origin = origins.HttpOrigin(
            f"{http_api.http_api_id}.execute-api.{self.region}.amazonaws.com",
        )

        distribution = cloudfront.Distribution(
            self, "Distribution",
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.S3BucketOrigin.with_origin_access_control(
                    ui_bucket, origin_access_control=oac,
                ),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
            ),
            additional_behaviors={
                "/api/*": cloudfront.BehaviorOptions(
                    origin=api_origin,
                    viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                    cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
                    allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
                    origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
                ),
            },
            default_root_object="index.html",
            error_responses=[
                cloudfront.ErrorResponse(
                    http_status=403,
                    response_http_status=200,
                    response_page_path="/index.html",
                ),
            ],
        )

        # Grant CloudFront access to UI bucket
        ui_bucket.add_to_resource_policy(iam.PolicyStatement(
            actions=["s3:GetObject"],
            resources=[ui_bucket.arn_for_objects("*")],
            principals=[iam.ServicePrincipal("cloudfront.amazonaws.com")],
            conditions={
                "StringEquals": {
                    "AWS:SourceArn": f"arn:aws:cloudfront::{self.account}:distribution/{distribution.distribution_id}"
                }
            },
        ))

        # Deploy frontend to S3 UI bucket
        s3_deploy.BucketDeployment(
            self, "DeployUI",
            sources=[s3_deploy.Source.asset(
                os.path.join(os.path.dirname(__file__), "../../frontend")
            )],
            destination_bucket=ui_bucket,
            distribution=distribution,
            distribution_paths=["/*"],
        )

        # ── Outputs ──────────────────────────────────────────────────────────

        CfnOutput(self, "AppUrl",
            value=f"https://{distribution.domain_name}",
            description="LEGO Sorting App URL",
        )
        CfnOutput(self, "ApiUrl",
            value=http_api.url,
            description="API Gateway URL",
        )
        CfnOutput(self, "ImagesBucketName",
            value=images_bucket.bucket_name,
            description="S3 bucket for image uploads",
        )
        CfnOutput(self, "CatalogLoaderFunctionName",
            value=catalog_loader_lambda.function_name,
            description="Invoke this Lambda once to load the Rebrickable parts catalog",
        )
