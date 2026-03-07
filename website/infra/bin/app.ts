#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { StaticSiteStack } from '../lib/static-site-stack.js';
import { GitHubOidcStack } from '../lib/github-oidc-stack.js';

const app = new cdk.App();

const domainName = app.node.tryGetContext('domainName') ?? 'wgnext.app';
const githubOrg = app.node.tryGetContext('githubOrg') ?? 'ryantenney';
const githubRepo = app.node.tryGetContext('githubRepo') ?? 'wgnext-apple';

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: 'us-east-1',
};

// The ACM certificate for CloudFront must be in us-east-1
const siteStack = new StaticSiteStack(app, 'WGnextSite', {
  env,
  domainName,
});

// GitHub Actions OIDC deploy role
new GitHubOidcStack(app, 'WGnextGitHubOidc', {
  env,
  githubOrg,
  githubRepo,
  siteBucketArn: siteStack.siteBucketArn,
  distributionArn: siteStack.distributionArn,
});
