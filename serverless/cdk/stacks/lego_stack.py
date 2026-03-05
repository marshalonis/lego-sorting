from aws_cdk import (
    Stack,
    Duration,
    RemovalPolicy,
    CfnOutput,
    BundlingOptions,
    ILocalBundling,
    AssetHashType,
    aws_dynamodb as dynamodb,
    aws_s3 as s3,
    aws_s3_deployment as s3_deploy,
    aws_lambda as lambda_,
    aws_apigatewayv2 as apigwv2,
    aws_apigatewayv2_integrations as integrations,
    aws_apigatewayv2_authorizers as apigwv2_auth,
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_iam as iam,
    aws_certificatemanager as acm,
    aws_cognito as cognito,
)
from constructs import Construct
import jsii
import os
import shutil
import subprocess
import sys


@jsii.implements(ILocalBundling)
class LocalPipBundler:
    """Bundles a Python Lambda using local pip — no Docker required."""

    def __init__(self, source_dir: str):
        self._source_dir = source_dir

    def try_bundle(self, output_dir: str, *, image, **kwargs) -> bool:
        try:
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "-r", "requirements.txt",
                 "-t", output_dir, "-q",
                 "--platform", "manylinux2014_x86_64",
                 "--implementation", "cp",
                 "--python-version", "3.12",
                 "--only-binary=:all:",
                 "--upgrade"],
                cwd=self._source_dir,
                check=True,
            )
            for item in os.listdir(self._source_dir):
                if item in ("__pycache__", "cdk.out"):
                    continue
                src = os.path.join(self._source_dir, item)
                dst = os.path.join(output_dir, item)
                if os.path.isdir(src):
                    shutil.copytree(src, dst, dirs_exist_ok=True)
                else:
                    shutil.copy2(src, dst)
            return True
        except Exception as e:
            print(f"Local bundling failed: {e}")
            return False

DOMAIN_NAME = "bootiak.org"
CERTIFICATE_ARN = "arn:aws:acm:us-east-1:535002893187:certificate/eb45b684-8ef9-4664-963c-173c91170cc9"


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

        # ── Cognito ──────────────────────────────────────────────────────────

        user_pool = cognito.UserPool(
            self, "UserPool",
            self_sign_up_enabled=False,
            sign_in_aliases=cognito.SignInAliases(email=True, username=False),
            removal_policy=RemovalPolicy.DESTROY,
        )

        user_pool_client = user_pool.add_client(
            "AppClient",
            auth_flows=cognito.AuthFlow(user_password=True),
            generate_secret=False,
        )

        jwt_authorizer = apigwv2_auth.HttpUserPoolAuthorizer(
            "CognitoAuthorizer",
            user_pool,
            user_pool_clients=[user_pool_client],
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

        _api_src = os.path.join(os.path.dirname(__file__), "../../lambda/api")
        api_lambda = lambda_.Function(
            self, "ApiLambda",
            runtime=lambda_.Runtime.PYTHON_3_12,
            code=lambda_.Code.from_asset(
                _api_src,
                asset_hash_type=AssetHashType.OUTPUT,
                bundling=BundlingOptions(
                    image=lambda_.Runtime.PYTHON_3_12.bundling_image,
                    local=LocalPipBundler(_api_src),
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
                "COGNITO_USER_POOL_ID": user_pool.user_pool_id,
                "COGNITO_CLIENT_ID": user_pool_client.user_pool_client_id,
            },
        )

        # Catalog loader — separate Lambda for one-time Rebrickable download
        _catalog_src = os.path.join(os.path.dirname(__file__), "../../lambda/catalog_loader")
        catalog_loader_lambda = lambda_.Function(
            self, "CatalogLoaderLambda",
            runtime=lambda_.Runtime.PYTHON_3_12,
            code=lambda_.Code.from_asset(
                _catalog_src,
                asset_hash_type=AssetHashType.OUTPUT,
                bundling=BundlingOptions(
                    image=lambda_.Runtime.PYTHON_3_12.bundling_image,
                    local=LocalPipBundler(_catalog_src),
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

        # Unauthenticated — returns Cognito config needed for login
        http_api.add_routes(
            path="/api/config",
            methods=[apigwv2.HttpMethod.GET],
            integration=lambda_integration,
        )

        # All other routes require a valid Cognito JWT
        http_api.add_routes(
            path="/{proxy+}",
            methods=[apigwv2.HttpMethod.ANY],
            integration=lambda_integration,
            authorizer=jwt_authorizer,
        )

        # ── CloudFront ────────────────────────────────────────────────────────

        # OAC for S3 UI bucket
        oac = cloudfront.S3OriginAccessControl(self, "OAC")

        # API Gateway origin
        api_origin = origins.HttpOrigin(
            f"{http_api.http_api_id}.execute-api.{self.region}.amazonaws.com",
        )

        certificate = acm.Certificate.from_certificate_arn(self, "Cert", CERTIFICATE_ARN)

        distribution = cloudfront.Distribution(
            self, "Distribution",
            domain_names=[DOMAIN_NAME],
            certificate=certificate,
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
            value=f"https://{DOMAIN_NAME}",
            description="LEGO Sorting App URL",
        )
        CfnOutput(self, "CloudFrontDomain",
            value=distribution.domain_name,
            description="Point your DNS CNAME/ALIAS to this CloudFront domain",
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
        CfnOutput(self, "UserPoolId",
            value=user_pool.user_pool_id,
            description="Cognito User Pool ID — create your user here in the AWS Console",
        )
        CfnOutput(self, "UserPoolClientId",
            value=user_pool_client.user_pool_client_id,
            description="Cognito App Client ID",
        )
