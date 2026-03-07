import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

interface GitHubOidcStackProps extends cdk.StackProps {
  /** GitHub org/user name */
  githubOrg: string;
  /** GitHub repository name */
  githubRepo: string;
  /** S3 bucket ARN that the deploy role needs access to */
  siteBucketArn: string;
  /** CloudFront distribution ARN for cache invalidation */
  distributionArn: string;
}

export class GitHubOidcStack extends cdk.Stack {
  public readonly deployRole: iam.Role;

  constructor(scope: Construct, id: string, props: GitHubOidcStackProps) {
    super(scope, id, props);

    const { githubOrg, githubRepo, siteBucketArn, distributionArn } = props;

    // Import the existing GitHub OIDC provider (one per AWS account).
    // The provider is shared across projects — security is enforced by
    // each role's trust policy, which is scoped to a specific repo.
    const oidcProviderArn = `arn:aws:iam::${this.account}:oidc-provider/token.actions.githubusercontent.com`;
    const oidcProvider = iam.OpenIdConnectProvider.fromOpenIdConnectProviderArn(
      this, 'GitHubOidc', oidcProviderArn,
    );

    // IAM role assumed by GitHub Actions via OIDC
    this.deployRole = new iam.Role(this, 'GitHubDeployRole', {
      roleName: 'wgnext-website-deploy',
      assumedBy: new iam.WebIdentityPrincipal(
        oidcProvider.openIdConnectProviderArn,
        {
          StringEquals: {
            'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
          },
          StringLike: {
            'token.actions.githubusercontent.com:sub': `repo:${githubOrg}/${githubRepo}:*`,
          },
        },
      ),
      maxSessionDuration: cdk.Duration.hours(1),
    });

    // S3: read/write site bucket
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          's3:GetObject',
          's3:PutObject',
          's3:DeleteObject',
          's3:ListBucket',
          's3:GetBucketLocation',
        ],
        resources: [siteBucketArn, `${siteBucketArn}/*`],
      }),
    );

    // CloudFront: invalidate cache
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'cloudfront:CreateInvalidation',
          'cloudfront:GetInvalidation',
          'cloudfront:GetDistribution',
        ],
        resources: [distributionArn],
      }),
    );

    // CloudFormation: manage the site stack
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'cloudformation:DescribeStacks',
          'cloudformation:DescribeStackEvents',
          'cloudformation:GetTemplate',
          'cloudformation:CreateStack',
          'cloudformation:UpdateStack',
          'cloudformation:DeleteStack',
          'cloudformation:CreateChangeSet',
          'cloudformation:ExecuteChangeSet',
          'cloudformation:DeleteChangeSet',
          'cloudformation:DescribeChangeSet',
          'cloudformation:GetTemplateSummary',
        ],
        resources: [
          `arn:aws:cloudformation:us-east-1:${this.account}:stack/WGnextSite/*`,
          `arn:aws:cloudformation:us-east-1:${this.account}:stack/WGnextGitHubOidc/*`,
          `arn:aws:cloudformation:us-east-1:${this.account}:stack/CDKToolkit/*`,
        ],
      }),
    );

    // SSM: CDK bootstrap version check
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['ssm:GetParameter'],
        resources: [
          `arn:aws:ssm:us-east-1:${this.account}:parameter/cdk-bootstrap/*`,
        ],
      }),
    );

    // STS: CDK uses GetCallerIdentity
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['sts:GetCallerIdentity'],
        resources: ['*'],
      }),
    );

    // CDK asset publishing: S3 staging bucket + ECR (for custom resources)
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          's3:GetObject',
          's3:PutObject',
          's3:ListBucket',
          's3:GetBucketLocation',
        ],
        resources: [
          `arn:aws:s3:::cdk-*-assets-${this.account}-us-east-1`,
          `arn:aws:s3:::cdk-*-assets-${this.account}-us-east-1/*`,
        ],
      }),
    );

    // IAM: CDK needs to pass roles for custom resources (BucketDeployment lambda)
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['iam:PassRole'],
        resources: [
          `arn:aws:iam::${this.account}:role/cdk-*`,
        ],
      }),
    );

    // CDK file asset publishing role assumption
    this.deployRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['sts:AssumeRole'],
        resources: [
          `arn:aws:iam::${this.account}:role/cdk-*-deploy-role-${this.account}-us-east-1`,
          `arn:aws:iam::${this.account}:role/cdk-*-file-publishing-role-${this.account}-us-east-1`,
          `arn:aws:iam::${this.account}:role/cdk-*-lookup-role-${this.account}-us-east-1`,
        ],
      }),
    );

    new cdk.CfnOutput(this, 'DeployRoleArn', {
      value: this.deployRole.roleArn,
      description: 'Set this as AWS_DEPLOY_ROLE_ARN in GitHub environment variables',
    });
  }
}
